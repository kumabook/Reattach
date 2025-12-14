use std::process::Command;

use crate::tmux::TmuxError;

pub fn send_keys(target: &str, text: &str) -> Result<(), TmuxError> {
    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, "-l", text])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, "Enter"])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}

pub fn send_escape(target: &str) -> Result<(), TmuxError> {
    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, "Escape"])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}
