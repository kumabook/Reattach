use std::process::Command;

use crate::tmux::TmuxError;

const SESSION_PREFIX: &str = "claude-";

pub fn create_session(name: &str, cwd: &str) -> Result<(), TmuxError> {
    let session_name = format!("{}{}", SESSION_PREFIX, name);

    let output = Command::new("tmux")
        .args([
            "new-session",
            "-d",
            "-s",
            &session_name,
            "-c",
            cwd,
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let output = Command::new("tmux")
        .args([
            "send-keys",
            "-t",
            &session_name,
            "claude",
            "Enter",
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}
