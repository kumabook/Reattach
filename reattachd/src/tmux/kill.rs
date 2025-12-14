use std::process::Command;

use crate::tmux::TmuxError;

pub fn kill_pane(target: &str) -> Result<(), TmuxError> {
    let output = Command::new("tmux")
        .args(["kill-pane", "-t", target])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}
