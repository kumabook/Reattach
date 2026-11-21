use std::hash::{Hash, Hasher};

const MAX_CONTEXT_LINES: usize = 8;
const MAX_CONTEXT_CHARS: usize = 600;
const MAX_LABEL_CHARS: usize = 80;
pub const MAX_CHOICES: usize = 6;

#[derive(Clone, Debug, PartialEq)]
pub struct Choice {
    pub number: String,
    pub label: String,
}

/// A numbered menu exactly as the terminal shows it, plus the lines that describe
/// what is being approved. The digest lets a later reply prove nothing changed.
#[derive(Clone, Debug, PartialEq)]
pub struct Prompt {
    pub context: String,
    pub choices: Vec<Choice>,
    pub digest: String,
}

impl Prompt {
    pub fn body(&self) -> String {
        let choices = self
            .choices
            .iter()
            .map(|c| format!("{}. {}", c.number, truncate(&c.label, MAX_LABEL_CHARS)))
            .collect::<Vec<_>>()
            .join("\n");
        if self.context.is_empty() {
            choices
        } else {
            format!("{}\n\n{choices}", self.context)
        }
    }
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_owned();
    }
    let mut out: String = text.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn strip_frame(line: &str) -> &str {
    line.trim().trim_matches(['│', '|', '┃']).trim()
}

fn is_rule(line: &str) -> bool {
    !line.is_empty() && line.chars().all(|c| "─━═-╌┄╭╮╰╯┌┐└┘".contains(c))
}

/// Same rules as the app's PermissionChoice.parse: the last consecutive group
/// containing the selection, numbered 1…n with exactly one selected item.
pub fn parse(screen: &str) -> Option<Prompt> {
    let lines: Vec<&str> = screen.lines().map(strip_frame).collect();
    let mut groups: Vec<(usize, Vec<(Choice, bool)>)> = Vec::new();
    let mut current: Vec<(Choice, bool)> = Vec::new();
    let mut start = 0;
    for (index, line) in lines.iter().enumerate() {
        if *line == "Press enter to confirm or esc to cancel"
            || *line == "enter to submit | esc to cancel"
        {
            break;
        }
        if let Some((choice, selected)) = parse_choice(line) {
            if choice.number == "1" && !current.is_empty() {
                groups.push((start, std::mem::take(&mut current)));
            }
            if current.is_empty() {
                start = index;
            }
            current.push((choice, selected));
        } else if !line.is_empty() && !current.is_empty() {
            let raw = screen.lines().nth(index).unwrap_or("");
            let indented = raw.trim_start_matches(['│', '|', '┃']).starts_with("  ");
            if indented && !is_rule(line) {
                let (last, _) = current.last_mut().unwrap();
                last.label = format!("{} {line}", last.label);
            } else {
                groups.push((start, std::mem::take(&mut current)));
            }
        }
    }
    if !current.is_empty() {
        groups.push((start, current));
    }
    let (start, group) = groups
        .into_iter()
        .rev()
        .find(|(_, group)| group.iter().any(|(_, selected)| *selected))?;
    if group.len() < 2
        || group.len() > MAX_CHOICES
        || group.iter().filter(|(_, selected)| *selected).count() != 1
        || group
            .iter()
            .enumerate()
            .any(|(i, (c, _))| c.number != (i + 1).to_string())
    {
        return None;
    }
    let mut context: Vec<&str> = lines[..start]
        .iter()
        .rev()
        .skip_while(|l| l.is_empty() || is_rule(l))
        .take_while(|l| !is_rule(l))
        .filter(|l| !l.is_empty())
        .take(MAX_CONTEXT_LINES)
        .copied()
        .collect();
    context.reverse();
    let context = truncate(&context.join("\n"), MAX_CONTEXT_CHARS);
    let choices: Vec<Choice> = group.into_iter().map(|(c, _)| c).collect();
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    context.hash(&mut hash);
    for choice in &choices {
        choice.number.hash(&mut hash);
        choice.label.hash(&mut hash);
    }
    Some(Prompt {
        context,
        choices,
        digest: format!("{:016x}", hash.finish()),
    })
}

fn parse_choice(line: &str) -> Option<(Choice, bool)> {
    let (selected, rest) = match line.strip_prefix(['❯', '›', '>', '▶', '▸']) {
        Some(rest) => (true, rest.trim_start()),
        None => (false, line),
    };
    let end = rest.find(|c: char| !c.is_ascii_digit())?;
    let (number, rest) = rest.split_at(end);
    if number.is_empty() || number.starts_with('0') {
        return None;
    }
    let label = rest.strip_prefix(['.', ')'])?;
    if !label.starts_with(char::is_whitespace) {
        return None;
    }
    let label = label.trim();
    if label.is_empty() {
        return None;
    }
    Some((
        Choice {
            number: number.to_owned(),
            label: label.to_owned(),
        },
        selected,
    ))
}

pub async fn capture(target: &str) -> Option<String> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        tokio::process::Command::new("tmux")
            .args(["capture-pane", "-p", "-t", target])
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

#[cfg(test)]
mod tests {
    use super::*;

    const CLAUDE: &str = "⏺ Bash(npm test)\n\n────────────────\n Bash command\n\n   npm test\n   Run the tests\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don't ask again for npm test commands in\n      /Users/me/project\n   3. No, and tell Claude what to do differently (esc)\n";

    #[test]
    fn extracts_command_and_choices() {
        let prompt = parse(CLAUDE).unwrap();
        assert_eq!(
            prompt.context,
            "Bash command\nnpm test\nRun the tests\nDo you want to proceed?"
        );
        assert_eq!(prompt.choices.len(), 3);
        assert_eq!(prompt.choices[0].label, "Yes");
        assert_eq!(
            prompt.choices[1].label,
            "Yes, and don't ask again for npm test commands in /Users/me/project"
        );
        assert!(prompt
            .body()
            .ends_with("3. No, and tell Claude what to do differently (esc)"));
    }

    #[test]
    fn digest_changes_with_the_command() {
        let other = CLAUDE.replace("npm test\n   Run", "rm -rf build\n   Run");
        assert_ne!(parse(CLAUDE).unwrap().digest, parse(&other).unwrap().digest);
        assert_eq!(parse(CLAUDE).unwrap().digest, parse(CLAUDE).unwrap().digest);
    }

    #[test]
    fn accepts_boxed_and_codex_menus() {
        let boxed =
            "│ Edit file?            │\n│ ❯ 1. Yes                │\n│   2. No                 │";
        let prompt = parse(boxed).unwrap();
        assert_eq!(prompt.context, "Edit file?");
        assert_eq!(prompt.choices.len(), 2);
        let codex = "Would you like to run the following command?\n\n  $ cargo test\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\n  Press enter to confirm or esc to cancel";
        assert_eq!(parse(codex).unwrap().choices.len(), 2);
    }

    #[test]
    fn ignores_options_below_a_separator() {
        let question = " ☐ Test\n│ Pick one\n❯ 1. Apple\n     First\n  2. Orange\n     Second\n  3. Type something.\n────────\n  4. Chat about this\nEnter to select · ↑/↓ to navigate · Esc to cancel";
        let prompt = parse(question).unwrap();
        assert_eq!(prompt.context, "☐ Test\nPick one");
        assert_eq!(prompt.choices.len(), 3);
        assert_eq!(prompt.choices[0].label, "Apple First");
    }

    #[test]
    fn rejects_lists_without_a_live_selection() {
        assert!(parse("  1. Yes\n  2. No\n").is_none());
        assert!(parse("❯ 1. Only one").is_none());
        assert!(parse("❯ 1. Yes\n  3. No").is_none());
        assert!(parse("> 2026 plans\n").is_none());
    }
}
