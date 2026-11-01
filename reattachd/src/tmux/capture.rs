use std::process::Command;

use serde::Serialize;

use crate::tmux::TmuxError;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PaneCursor {
    pub x: u32,
    pub row_from_bottom: u32,
    pub pane_width: u32,
    pub visible: bool,
}

pub struct PaneSnapshot {
    pub output: String,
    pub cursor: PaneCursor,
}

pub fn capture_pane(target: &str, lines: u32) -> Result<String, TmuxError> {
    let start_line = format!("-{}", lines);

    let output = Command::new("tmux")
        .args(["capture-pane", "-t", target, "-p", "-e", "-S", &start_line])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn capture_pane_snapshot(target: &str, lines: u32) -> Result<PaneSnapshot, TmuxError> {
    let output = capture_pane(target, lines)?;
    let cursor = capture_cursor(target)?;
    Ok(PaneSnapshot { output, cursor })
}

fn capture_cursor(target: &str) -> Result<PaneCursor, TmuxError> {
    // Use a printable delimiter: tmux can sanitize tabs to underscores when
    // the client runs without a terminal (as it does under launchd).
    let output = Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-t",
            target,
            "#{cursor_x}|#{cursor_y}|#{pane_width}|#{pane_height}|#{cursor_flag}",
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let metadata = String::from_utf8_lossy(&output.stdout);
    parse_cursor(&metadata)
        .map_err(|error| TmuxError::Command(format!("{error}; cursor metadata: {metadata:?}")))
}

fn parse_cursor(value: &str) -> Result<PaneCursor, TmuxError> {
    let mut fields = value.trim().split('|');
    let x = parse_cursor_field(fields.next(), "x")?;
    let y = parse_cursor_field(fields.next(), "y")?;
    let pane_width = parse_cursor_field(fields.next(), "pane width")?;
    let pane_height = parse_cursor_field(fields.next(), "pane height")?;
    let visible = fields.next() == Some("1");

    if fields.next().is_some() || pane_height == 0 {
        return Err(TmuxError::Command(format!(
            "invalid tmux cursor metadata: {value:?}"
        )));
    }

    Ok(PaneCursor {
        x,
        row_from_bottom: pane_height.saturating_sub(y.saturating_add(1)),
        pane_width,
        visible,
    })
}

fn parse_cursor_field(value: Option<&str>, name: &str) -> Result<u32, TmuxError> {
    value
        .and_then(|field| field.parse().ok())
        .ok_or_else(|| TmuxError::Command(format!("invalid tmux cursor {name}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cursor_position_relative_to_pane_bottom() {
        assert_eq!(
            parse_cursor("12|3|80|24|1\n").unwrap(),
            PaneCursor {
                x: 12,
                row_from_bottom: 20,
                pane_width: 80,
                visible: true,
            }
        );
    }

    #[test]
    fn rejects_invalid_cursor_metadata() {
        assert!(parse_cursor("12|3|80|0|1").is_err());
        assert!(parse_cursor("missing fields").is_err());
    }

    #[test]
    fn parses_printable_delimited_cursor_metadata() {
        for (metadata, x, row_from_bottom, visible) in [
            ("2|79|338|83|1\n", 2, 3, true),
            ("0|0|80|24|0\n", 0, 23, false),
            ("79|23|80|24|1\n", 79, 0, true),
        ] {
            let cursor = parse_cursor(metadata).unwrap();
            assert_eq!(cursor.x, x);
            assert_eq!(cursor.row_from_bottom, row_from_bottom);
            assert_eq!(cursor.visible, visible);
        }
    }
}
