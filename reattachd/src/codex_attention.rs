//! Read-only fallback for Codex command approvals missing a lifecycle hook.
use std::collections::HashMap;

use crate::attention::Attention;

const HEADER: &str = "Would you like to run the following command?";
const FOOTER: &str = "Press enter to confirm or esc to cancel";

#[derive(Default)]
pub struct Detector {
    observed: HashMap<String, (String, i64)>,
}

impl Detector {
    pub async fn scan(&mut self) -> Vec<Attention> {
        let Some(panes) = tmux(&[
            "list-panes", "-a", "-f", "#{!=:#{@reattach_private},1}", "-F",
            "#{pid}|#{pane_id}|#{pane_current_command}|#{pane_in_mode}|#{pane_dead}|#{session_name}:#{window_index}.#{pane_index}",
        ]).await else {
            self.observed.clear();
            return vec![];
        };
        let mut captures = tokio::task::JoinSet::new();
        for line in panes.lines() {
            let fields: Vec<_> = line.splitn(6, '|').collect();
            if fields.len() != 6 || fields[2] != "codex" || fields[3] != "0" || fields[4] != "0" {
                continue;
            }
            let identity = format!("{}|{}", fields[0], fields[1]);
            let pane = fields[1].to_owned();
            let target = fields[5].to_owned();
            captures.spawn(async move {
                // Capture only the live visible grid: never scan scrollback or copy mode.
                let text = tmux(&["capture-pane", "-p", "-t", &pane, "-S", "0", "-E", "-"]).await?;
                Some((identity, target, command_prompt(&text)?))
            });
        }
        let mut current = Vec::new();
        while let Some(result) = captures.join_next().await {
            if let Ok(Some(prompt)) = result {
                current.push(prompt);
            }
        }
        self.reconcile(current, chrono::Utc::now().timestamp())
    }

    fn reconcile(&mut self, current: Vec<(String, String, String)>, now: i64) -> Vec<Attention> {
        let mut next = HashMap::new();
        let entries = current
            .into_iter()
            .map(|(identity, target, prompt)| {
                let received_at = self
                    .observed
                    .get(&identity)
                    .filter(|(previous, _)| previous == &prompt)
                    .map(|(_, time)| *time)
                    .unwrap_or(now);
                next.insert(identity, (prompt, received_at));
                Attention {
                    target,
                    tool: "Codex".into(),
                    received_at,
                }
            })
            .collect();
        self.observed = next;
        entries
    }
}

async fn tmux(args: &[&str]) -> Option<String> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("tmux")
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn command_prompt(text: &str) -> Option<String> {
    let lines: Vec<_> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    // Only a live prompt at the bottom of the visible grid is eligible.
    let tool_prompt = *lines.last()? == "enter to submit | esc to cancel";
    if !tool_prompt && *lines.last()? != FOOTER {
        return None;
    }
    let start = lines.iter().rposition(|line| {
        if tool_prompt {
            line.starts_with("Allow ") && line.contains(" to run tool \"") && line.ends_with("\"?")
        } else {
            *line == HEADER
        }
    })?;
    let prompt = &lines[start..];
    let mut numbers = Vec::new();
    let mut selected = 0;
    let mut approve = false;
    let mut deny = false;
    let mut tool_labels = Vec::new();
    for line in prompt {
        let clean = line.trim_start_matches(['›', '❯', '>']).trim_start();
        let Some((number, label)) = clean.split_once(". ") else {
            continue;
        };
        let Ok(number) = number.parse::<usize>() else {
            continue;
        };
        if clean != *line {
            selected += 1;
        }
        numbers.push(number);
        if tool_prompt {
            // Descriptions form a second column; retain them in the identity.
            let label = label.split("  ").next().unwrap_or(label).trim();
            tool_labels.push(label);
        }
        approve |= number == 1 && label == "Yes, proceed (y)";
        deny |= label == "No, and tell Codex what to do differently (esc)";
    }
    let valid_labels = if tool_prompt {
        tool_labels == ["Allow", "Allow for this session", "Always allow", "Cancel"]
    } else {
        approve && deny
    };
    if !valid_labels
        || selected != 1
        || numbers.len() < 2
        || numbers.iter().enumerate().any(|(i, n)| *n != i + 1)
    {
        return None;
    }
    Some(
        prompt
            .iter()
            .map(|line| line.trim_start_matches(['›', '❯', '>']).trim_start())
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    const PROMPT: &str = "Would you like to run the following command?\n\nEnvironment: local\nReason: Build the app\n$ xcodebuild -project App.xcodeproj\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `xcodebuild\n     -project App.xcodeproj` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel\n";

    #[test]
    fn recognizes_screenshot_prompt_with_wrapping_and_blank_grid_rows() {
        assert!(command_prompt(&format!("Old output\n{PROMPT}{}", "\n".repeat(100))).is_some());
        assert!(command_prompt(&PROMPT.replace('›', "❯")).is_some());
    }

    #[test]
    fn ignores_history_incomplete_and_unrelated_menus() {
        for text in [
            format!("{PROMPT}\nWorking (2s)"),
            PROMPT.replace(HEADER, "Documentation example"),
            PROMPT.replace(FOOTER, ""),
            PROMPT.replace("Yes, proceed (y)", "Pick blue"),
            PROMPT.replace("› ", "  "),
            PROMPT.replace("  3.", "  4."),
        ] {
            assert!(command_prompt(&text).is_none(), "{text}");
        }
    }

    const TOOL_PROMPT: &str = "Field 1/1\nAllow Vercel to run tool \"vercel.update_project\"?\n\nidOrName: example\nrequestBody: {\"nodeVersion\":\"22.x\"}\nteamId: example\n\n› 1. Allow                     Run the tool and continue\n  2. Allow for this session    Run the tool and remember this choice for this session\n  3. Always allow              Run the tool and remember this choice for future tool calls\n  4. Cancel                    Cancel this tool call\nenter to submit | esc to cancel\n";

    #[test]
    fn recognizes_tool_approval_but_not_history_or_arbitrary_menus() {
        assert!(command_prompt(TOOL_PROMPT).is_some());
        assert!(command_prompt(&format!("{TOOL_PROMPT}\nWorking")).is_none());
        assert!(command_prompt(&TOOL_PROMPT.replace("Always allow", "Choose blue")).is_none());
        assert!(command_prompt(
            &TOOL_PROMPT.replace("Allow Vercel to run tool", "Documentation for tool")
        )
        .is_none());
        assert!(command_prompt(&TOOL_PROMPT.replace("  4.", "  5.")).is_none());
        assert!(command_prompt(&TOOL_PROMPT.replace("› 1.", "  1.")).is_none());
        let moved = TOOL_PROMPT.replace("› 1.", "  1.").replace("  2.", "› 2.");
        assert_eq!(command_prompt(TOOL_PROMPT), command_prompt(&moved));
        let changed = TOOL_PROMPT.replace("22.x", "24.x");
        assert_ne!(command_prompt(TOOL_PROMPT), command_prompt(&changed));
    }

    #[test]
    fn keeps_identity_until_prompt_changes_and_removes_resolved_or_closed_panes() {
        let mut detector = Detector::default();
        let prompt = || vec![("123|%1".into(), "dev:0.0".into(), PROMPT.into())];
        assert_eq!(detector.reconcile(prompt(), 10)[0].received_at, 10);
        assert_eq!(detector.reconcile(prompt(), 20)[0].received_at, 10);
        let changed = vec![(
            "123|%1".into(),
            "dev:0.0".into(),
            PROMPT.replace("Build", "Test"),
        )];
        assert_eq!(detector.reconcile(changed, 30)[0].received_at, 30);
        assert!(detector.reconcile(vec![], 40).is_empty());
        assert_eq!(detector.reconcile(prompt(), 50)[0].received_at, 50);
    }
}
