use std::process::Command;

use serde::Serialize;

use crate::tmux::TmuxError;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PaneCursor {
    pub x: u32,
    pub row_from_bottom: u32,
    pub pane_width: u32,
    pub visible: bool,
    pub copy_mode: bool,
    pub selection: Vec<SelectionSpan>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SelectionSpan {
    pub row_from_bottom: u32,
    pub start_x: u32,
    pub end_x: u32,
}

pub struct PaneSnapshot {
    pub output: String,
    pub cursor: PaneCursor,
}

pub fn capture_pane(target: &str, lines: u32) -> Result<String, TmuxError> {
    Ok(snapshot_at(None, target, lines)?.output)
}

fn tmux_command(socket: Option<&str>) -> Command {
    let mut command = Command::new("tmux");
    if let Some(socket) = socket {
        command.args(["-S", socket]);
    }
    command
}

fn capture_at(socket: Option<&str>, target: &str, lines: u32) -> Result<String, TmuxError> {
    // -M exposes the copy-mode backing grid, not just its visible viewport.
    // Use tmux format expansion so scrolling beyond the usual history limit
    // still captures exactly the rows under the copy cursor.
    let start_line = "#{?#{==:#{pane_mode},copy-mode},#{e|-:0,#{scroll_position}},-LINES}"
        .replace("LINES", &lines.to_string());
    let end_line =
        "#{e|-:#{e|-:#{pane_height},1},#{?#{==:#{pane_mode},copy-mode},#{scroll_position},0}}";

    let output = tmux_command(socket)
        .args([
            "capture-pane",
            "-t",
            target,
            "-p",
            "-e",
            "-M",
            "-S",
            &start_line,
            "-E",
            end_line,
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

pub fn capture_pane_snapshot(target: &str, lines: u32) -> Result<PaneSnapshot, TmuxError> {
    snapshot_at(None, target, lines)
}

fn snapshot_at(socket: Option<&str>, target: &str, lines: u32) -> Result<PaneSnapshot, TmuxError> {
    let metadata = cursor_metadata(socket, target)?;
    let mut fields: Vec<String> = metadata.trim().split('|').map(str::to_owned).collect();
    let cursor = parse_cursor(&metadata)?;
    if !cursor.copy_mode {
        return Ok(PaneSnapshot {
            output: capture_at(socket, target, lines)?,
            cursor,
        });
    }
    // Copy mode owns a frozen backing grid. The live pane's history_size can
    // keep growing while it is open, so derive selection offsets from that
    // frozen grid rather than the running application's history.
    let captured = tmux_command(socket)
        .args([
            "capture-pane",
            "-t",
            target,
            "-p",
            "-e",
            "-M",
            "-S",
            "-",
            "-E",
            "-",
        ])
        .output()?;
    if !captured.status.success() {
        return Err(TmuxError::Command(
            String::from_utf8_lossy(&captured.stderr).into(),
        ));
    }
    let backing = String::from_utf8_lossy(&captured.stdout);
    let rows: Vec<_> = backing.split_terminator('\n').collect();
    let height = parse_cursor_field(fields.get(3).map(String::as_str), "height")? as usize;
    let scroll = parse_cursor_field(fields.get(11).map(String::as_str), "scroll")? as usize;
    let history = rows.len().saturating_sub(height);
    fields[12] = history.to_string();
    let top = history.saturating_sub(scroll);
    let bottom = (top + height).min(rows.len());
    let output = format!("{}\n", rows[top..bottom].join("\n"));
    Ok(PaneSnapshot {
        output,
        cursor: parse_cursor(&fields.join("|"))?,
    })
}

#[cfg(test)]
fn capture_cursor(socket: Option<&str>, target: &str) -> Result<PaneCursor, TmuxError> {
    parse_cursor(&cursor_metadata(socket, target)?)
}

fn cursor_metadata(socket: Option<&str>, target: &str) -> Result<String, TmuxError> {
    // Use a printable delimiter: tmux can sanitize tabs to underscores when
    // the client runs without a terminal (as it does under launchd).
    let output = tmux_command(socket)
        .args([
            "display-message",
            "-p",
            "-t",
            target,
            concat!(
                "#{?#{==:#{pane_mode},copy-mode},#{copy_cursor_x},#{cursor_x}}|",
                "#{?#{==:#{pane_mode},copy-mode},#{copy_cursor_y},#{cursor_y}}|",
                "#{pane_width}|#{pane_height}|",
                "#{?#{==:#{pane_mode},copy-mode},1,#{cursor_flag}}|",
                "#{==:#{pane_mode},copy-mode}|#{||:#{selection_active},#{selection_present}}|",
                "#{selection_start_x}|#{selection_start_y}|#{selection_end_x}|#{selection_end_y}|",
                "#{scroll_position}|#{history_size}|#{rectangle_toggle}|#{mode-keys}"
            ),
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(String::from_utf8_lossy(&output.stdout).into())
}

fn parse_cursor(value: &str) -> Result<PaneCursor, TmuxError> {
    let mut fields = value.trim().split('|');
    let x = parse_cursor_field(fields.next(), "x")?;
    let y = parse_cursor_field(fields.next(), "y")?;
    let pane_width = parse_cursor_field(fields.next(), "pane width")?;
    let pane_height = parse_cursor_field(fields.next(), "pane height")?;
    let visible = fields.next() == Some("1");

    let mode_fields: Vec<_> = fields.collect();
    if (!mode_fields.is_empty() && mode_fields.len() != 10) || pane_height == 0 {
        return Err(TmuxError::Command(format!(
            "invalid tmux cursor metadata: {value:?}"
        )));
    }

    let copy_mode = mode_fields.first() == Some(&"1");
    let selection = if copy_mode && mode_fields.get(1) == Some(&"1") {
        selection_spans(&mode_fields, pane_width, pane_height)?
    } else {
        Vec::new()
    };
    Ok(PaneCursor {
        x,
        row_from_bottom: pane_height.saturating_sub(y.saturating_add(1)),
        pane_width,
        visible,
        copy_mode,
        selection,
    })
}

// Selection coordinates are in the backing history grid. Return only the
// visible cells, with an exclusive right edge for the iOS overlay.
fn selection_spans(
    fields: &[&str],
    width: u32,
    height: u32,
) -> Result<Vec<SelectionSpan>, TmuxError> {
    let number = |index| parse_cursor_field(fields.get(index).copied(), "selection");
    let (sx, sy, ex, ey) = (number(2)?, number(3)?, number(4)?, number(5)?);
    let top = number(7)?.saturating_sub(number(6)?);
    let rectangle = fields[8] == "1";
    let inclusive = fields[9] == "vi" || rectangle;
    let ((ax, ay), (bx, by)) = if (sy, sx) <= (ey, ex) {
        ((sx, sy), (ex, ey))
    } else {
        ((ex, ey), (sx, sy))
    };
    let mut spans = Vec::new();
    for row in 0..height {
        let y = top.saturating_add(row);
        if y < ay || y > by {
            continue;
        }
        let start = if rectangle {
            sx.min(ex)
        } else if y == ay {
            ax
        } else {
            0
        };
        let end = if rectangle {
            sx.max(ex).saturating_add(1)
        } else if y == by {
            bx.saturating_add(u32::from(inclusive))
        } else {
            width
        };
        if start.min(width) < end.min(width) {
            spans.push(SelectionSpan {
                row_from_bottom: height - row - 1,
                start_x: start.min(width),
                end_x: end.min(width),
            });
        }
    }
    Ok(spans)
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
    fn copy_selection_tracks_scrollback_reverse_and_rectangle() {
        let forward = parse_cursor("8|2|80|4|1|1|1|3|101|8|102|9|110|0|emacs").unwrap();
        assert!(forward.copy_mode);
        assert_eq!(forward.row_from_bottom, 1);
        assert_eq!(
            forward.selection,
            vec![
                SelectionSpan {
                    row_from_bottom: 3,
                    start_x: 3,
                    end_x: 80
                },
                SelectionSpan {
                    row_from_bottom: 2,
                    start_x: 0,
                    end_x: 8
                },
            ]
        );
        let reverse = parse_cursor("3|0|80|4|1|1|1|8|102|3|101|9|110|0|emacs").unwrap();
        assert_eq!(forward.selection, reverse.selection);
        let rectangle = parse_cursor("3|0|80|4|1|1|1|8|102|3|101|9|110|1|emacs").unwrap();
        assert_eq!(
            rectangle.selection,
            vec![
                SelectionSpan {
                    row_from_bottom: 3,
                    start_x: 3,
                    end_x: 9
                },
                SelectionSpan {
                    row_from_bottom: 2,
                    start_x: 3,
                    end_x: 9
                },
            ]
        );
        let vi = parse_cursor("8|2|80|4|1|1|1|3|101|8|102|9|110|0|vi").unwrap();
        assert_eq!(vi.selection[1].end_x, 9);
        assert!(parse_cursor("0|0|80|4|1|1|1|0|5|9|6|0|110|0|emacs")
            .unwrap()
            .selection
            .is_empty());
    }

    #[tokio::test]
    #[ignore = "requires permission to start an isolated tmux server"]
    async fn captures_copy_mode_viewport_cursor_and_selection() {
        use super::super::control::command;
        let socket = format!("/tmp/reattach-mode-{}.sock", uuid::Uuid::new_v4());
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = Command::new("tmux")
                    .args(["-S", &self.0, "kill-server"])
                    .output();
            }
        }
        let _cleanup = Cleanup(socket.clone());
        let sock = Some(socket.as_str());
        command(sock, &["-f", "/dev/null", "new-session", "-d", "-x", "80", "-y", "10", "-s", "probe", "i=1; while [ $i -le 600 ]; do printf 'line-%02d 日本語 https://example.com\\n' $i; i=$((i+1)); done; sleep 1; i=1; while [ $i -le 30 ]; do printf 'live-output\\n'; i=$((i+1)); done; sleep 60"]).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!capture_cursor(sock, "probe").unwrap().copy_mode);
        command(
            sock,
            &["set-option", "-w", "-t", "probe", "mode-keys", "emacs"],
        )
        .await
        .unwrap();
        command(sock, &["copy-mode", "-t", "probe"]).await.unwrap();
        for action in [
            "history-top",
            "start-of-line",
            "begin-selection",
            "cursor-right",
            "cursor-right",
        ] {
            command(sock, &["send-keys", "-t", "probe", "-X", action])
                .await
                .unwrap();
        }
        let cursor = capture_cursor(sock, "probe").unwrap();
        assert!(cursor.copy_mode && cursor.visible);
        assert_eq!(cursor.x, 2);
        assert_eq!(cursor.row_from_bottom, 9);
        assert_eq!(
            cursor.selection,
            vec![SelectionSpan {
                row_from_bottom: 9,
                start_x: 0,
                end_x: 2
            }]
        );
        let snapshot = snapshot_at(sock, "probe", 500).unwrap();
        assert_eq!(snapshot.cursor.selection, cursor.selection);
        let output = snapshot.output;
        assert_eq!(output.lines().count(), 10);
        assert!(
            output.contains("line-01 日本語 https://example.com"),
            "{output:?}"
        );
        assert!(!output.contains("line-600"));
        tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
        let frozen = snapshot_at(sock, "probe", 500).unwrap();
        assert_eq!(frozen.output, output);
        assert_eq!(frozen.cursor.selection, cursor.selection);
        command(sock, &["send-keys", "-t", "probe", "-X", "cancel"])
            .await
            .unwrap();
        let normal = capture_cursor(sock, "probe").unwrap();
        assert!(!normal.copy_mode && normal.selection.is_empty());
        assert!(capture_at(sock, "probe", 500)
            .unwrap()
            .contains("live-output"));
    }

    #[test]
    fn parses_cursor_position_relative_to_pane_bottom() {
        assert_eq!(
            parse_cursor("12|3|80|24|1\n").unwrap(),
            PaneCursor {
                x: 12,
                row_from_bottom: 20,
                pane_width: 80,
                visible: true,
                copy_mode: false,
                selection: Vec::new(),
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
