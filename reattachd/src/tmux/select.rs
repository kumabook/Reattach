use super::TmuxError;
use std::process::Command;

pub fn select_pane(target: &str) -> Result<(), TmuxError> {
    let output = Command::new("tmux").args(selection_args(target)).output()?;
    if !output.status.success() {
        return Err(TmuxError::Command(
            String::from_utf8_lossy(&output.stderr).trim().into(),
        ));
    }
    Ok(())
}

pub(super) fn selection_args(target: &str) -> Vec<&str> {
    vec![
        "select-window",
        "-t",
        target,
        ";",
        "select-pane",
        "-t",
        target,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selects_window_and_pane_as_separate_arguments() {
        assert_eq!(
            selection_args("work:2.1"),
            vec![
                "select-window",
                "-t",
                "work:2.1",
                ";",
                "select-pane",
                "-t",
                "work:2.1"
            ]
        );
    }
}
