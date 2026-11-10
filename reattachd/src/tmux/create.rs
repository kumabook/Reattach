use crate::tmux::TmuxError;
use std::process::Command;

const TARGET_FORMAT: &str = "#{session_name}:#{window_index}.#{pane_index}";

pub fn create_session(name: &str, cwd: &str) -> Result<String, TmuxError> {
    if name.trim().is_empty() {
        return Err(TmuxError::Command("session name is required".into()));
    }
    run(&session_args(name, cwd))
}

fn session_args<'a>(name: &'a str, cwd: &'a str) -> Vec<&'a str> {
    let mut args = vec!["new-session", "-d", "-P", "-F", TARGET_FORMAT, "-s", name];
    if !cwd.is_empty() {
        args.extend(["-c", cwd]);
    }
    args
}

pub fn create_window(target: &str, independent: bool) -> Result<String, TmuxError> {
    let session = run(&["display-message", "-p", "-t", target, "#{session_id}"])?;
    let cwd = run(&[
        "display-message",
        "-p",
        "-t",
        target,
        "#{pane_current_path}",
    ])?;
    let destination = format!("{session}:");
    run(&window_args(&destination, &cwd, independent))
}

pub(super) fn window_args<'a>(session: &'a str, cwd: &'a str, independent: bool) -> Vec<&'a str> {
    let mut args = vec![
        "new-window",
        "-P",
        "-F",
        TARGET_FORMAT,
        "-t",
        session,
        "-c",
        cwd,
    ];
    if independent {
        args.insert(1, "-d");
    }
    args
}

#[derive(Clone, Copy, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDirection {
    LeftRight,
    TopBottom,
}

pub fn split_pane(
    target: &str,
    direction: SplitDirection,
    independent: bool,
) -> Result<String, TmuxError> {
    let cwd = run(&[
        "display-message",
        "-p",
        "-t",
        target,
        "#{pane_current_path}",
    ])?;
    run(&split_args(target, &cwd, direction, independent))
}

fn split_args<'a>(
    target: &'a str,
    cwd: &'a str,
    direction: SplitDirection,
    independent: bool,
) -> Vec<&'a str> {
    let axis = match direction {
        SplitDirection::LeftRight => "-h",
        SplitDirection::TopBottom => "-v",
    };
    let mut args = vec![
        "split-window",
        axis,
        "-P",
        "-F",
        TARGET_FORMAT,
        "-t",
        target,
        "-c",
        cwd,
    ];
    if independent {
        args.insert(1, "-d");
    }
    args
}

fn run(args: &[&str]) -> Result<String, TmuxError> {
    let output = Command::new("tmux").args(args).output()?;
    if !output.status.success() {
        return Err(TmuxError::Command(
            String::from_utf8_lossy(&output.stderr).trim().into(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_arguments_preserve_target_directory_axis_and_selection() {
        for (direction, axis) in [
            (SplitDirection::LeftRight, "-h"),
            (SplitDirection::TopBottom, "-v"),
        ] {
            for independent in [false, true] {
                let args = split_args(
                    "project:2.1",
                    "/tmp/path with spaces",
                    direction,
                    independent,
                );
                assert!(args.contains(&axis));
                assert_eq!(args.contains(&"-d"), independent);
                assert_eq!(
                    &args[args.len() - 4..],
                    &["-t", "project:2.1", "-c", "/tmp/path with spaces"]
                );
            }
        }
    }

    #[test]
    #[ignore = "starts an isolated tmux server"]
    fn splits_real_panes_in_both_directions_without_changing_independent_selection() {
        let socket = format!("/tmp/reattach-split-{}.sock", uuid::Uuid::new_v4());
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = Command::new("tmux")
                    .args(["-S", &self.0, "kill-server"])
                    .output();
            }
        }
        let _cleanup = Cleanup(socket.clone());
        let run = |args: &[&str]| {
            let out = Command::new("tmux")
                .args(["-S", &socket])
                .args(args)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            String::from_utf8(out.stdout).unwrap().trim().to_owned()
        };
        run(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "split",
            "-x",
            "120",
            "-y",
            "40",
            "-c",
            "/tmp",
        ]);
        let target = run(&["display-message", "-p", "-t", "split:", TARGET_FORMAT]);
        let cwd = run(&[
            "display-message",
            "-p",
            "-t",
            &target,
            "#{pane_current_path}",
        ]);
        let left = run(&split_args(&target, &cwd, SplitDirection::LeftRight, true));
        assert_ne!(target, left);
        assert_eq!(
            run(&["display-message", "-p", "-t", "split:", TARGET_FORMAT]),
            target
        );
        let geometry = |pane: &str| -> Vec<u32> {
            run(&[
                "display-message",
                "-p",
                "-t",
                pane,
                "#{pane_left} #{pane_top} #{pane_width} #{pane_height}",
            ])
            .split_whitespace()
            .map(|v| v.parse().unwrap())
            .collect()
        };
        let a = geometry(&target);
        let b = geometry(&left);
        assert!(b[0] > a[0]);
        assert_eq!(a[1], b[1]);
        assert_eq!(
            run(&["display-message", "-p", "-t", &left, "#{pane_current_path}"]),
            cwd
        );
        let bottom = run(&split_args(&left, &cwd, SplitDirection::TopBottom, false));
        let b = geometry(&left);
        let c = geometry(&bottom);
        assert_eq!(b[0], c[0]);
        assert!(c[1] > b[1]);
        assert_eq!(
            run(&["display-message", "-p", "-t", "split:", TARGET_FORMAT]),
            bottom
        );
    }

    #[test]
    fn session_creation_uses_requested_name_and_default_shell() {
        assert_eq!(
            session_args("work", ""),
            vec!["new-session", "-d", "-P", "-F", TARGET_FORMAT, "-s", "work"]
        );
        let args = session_args("work", "/tmp/path with spaces");
        assert_eq!(&args[args.len() - 2..], &["-c", "/tmp/path with spaces"]);
        assert!(!args.contains(&"claude"));
    }
    #[test]
    fn independent_window_creation_does_not_select_the_window() {
        let args = window_args("$1:", "/tmp", true);
        assert_eq!(&args[..2], &["new-window", "-d"]);
        assert!(!window_args("$1:", "/tmp", false).contains(&"-d"));
    }

    #[test]
    fn window_creation_targets_session_and_preserves_directory_argument() {
        assert_eq!(
            window_args("$1:", "/tmp/path with spaces", false),
            vec![
                "new-window",
                "-P",
                "-F",
                TARGET_FORMAT,
                "-t",
                "$1:",
                "-c",
                "/tmp/path with spaces"
            ]
        );
    }
}
