use std::process::Command;

use crate::tmux::TmuxError;

pub fn capture_pane(target: &str, lines: u32) -> Result<String, TmuxError> {
    let start_line = format!("-{}", lines);

    let output = Command::new("tmux")
        .args([
            "capture-pane",
            "-t",
            target,
            "-p",
            "-e",
            "-S",
            &start_line,
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
