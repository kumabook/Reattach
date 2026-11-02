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

pub fn create_window(target: &str) -> Result<String, TmuxError> {
    let session = run(&["display-message", "-p", "-t", target, "#{session_id}"])?;
    let cwd = run(&[
        "display-message",
        "-p",
        "-t",
        target,
        "#{pane_current_path}",
    ])?;
    run(&window_args(&format!("{session}:"), &cwd))
}

pub(super) fn window_args<'a>(session: &'a str, cwd: &'a str) -> Vec<&'a str> {
    vec![
        "new-window",
        "-P",
        "-F",
        TARGET_FORMAT,
        "-t",
        session,
        "-c",
        cwd,
    ]
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
    fn window_creation_targets_session_and_preserves_directory_argument() {
        assert_eq!(
            window_args("$1:", "/tmp/path with spaces"),
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
