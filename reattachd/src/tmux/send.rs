use std::{process::Command, thread, time::Duration};

use crate::tmux::TmuxError;

const SUBMIT_DELAY: Duration = Duration::from_millis(100);

pub fn send_keys(target: &str, text: &str) -> Result<(), TmuxError> {
    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, "-l", text])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    // Keep the submit key out of terminal applications' rapid-input/paste
    // detection so that it is consistently handled as Enter.
    thread::sleep(SUBMIT_DELAY);

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
