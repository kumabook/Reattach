use serde::Serialize;
use std::process::Command;

use crate::tmux::TmuxError;

#[derive(Debug, Serialize)]
pub struct PaneGeometry {
    pub left: u32,
    pub top: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Serialize)]
pub struct Pane {
    pub index: u32,
    pub active: bool,
    pub target: String,
    pub current_path: String,
    pub geometry: PaneGeometry,
}

#[derive(Debug, Serialize)]
pub struct PaneBorders {
    pub style: String,
    pub active_style: String,
    pub indicators: String,
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: Vec<Pane>,
    pub width: u32,
    pub height: u32,
    pub zoomed: bool,
    pub borders: Option<PaneBorders>,
}

#[derive(Debug, Serialize)]
pub struct Session {
    pub name: String,
    pub attached: bool,
    pub windows: Vec<Window>,
}

pub fn list_sessions() -> Result<Vec<Session>, TmuxError> {
    list_sessions_at(None)
}

fn list_sessions_at(socket: Option<&str>) -> Result<Vec<Session>, TmuxError> {
    let mut command = Command::new("tmux");
    if let Some(socket) = socket {
        command.args(["-S", socket]);
    }
    let output = command.args([
            "list-panes",
            "-a",
            "-f", "#{!=:#{@reattach_private},1}",
            "-F",
            "#{session_name}|#{session_attached}|#{window_index}|#{window_name}|#{window_active}|#{pane_index}|#{pane_active}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{window_width}|#{window_height}|#{window_zoomed_flag}|#{pane_current_path}",
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("no server running")
            || stderr.contains("no sessions")
            || stderr.contains("No such file or directory")
        {
            return Ok(vec![]);
        }
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut sessions = parse_sessions(&stdout);
    // Query effective window options separately so unsupported styles never
    // interfere with parsing pane geometry or paths.
    let mut command = Command::new("tmux");
    if let Some(socket) = socket {
        command.args(["-S", socket]);
    }
    if let Ok(output) = command.args([
        "list-windows", "-a", "-F",
        "#{session_name}:#{window_index}|#{pane-border-indicators}|#{pane-border-style}|#{pane-active-border-style}",
    ]).output() {
        if output.status.success() {
            apply_borders(&mut sessions, &String::from_utf8_lossy(&output.stdout));
        }
    }
    Ok(sessions)
}

fn apply_borders(sessions: &mut [Session], output: &str) {
    for line in output.lines() {
        let parts: Vec<_> = line.split('|').collect();
        if parts.len() != 4 {
            continue;
        }
        for session in sessions.iter_mut() {
            for window in &mut session.windows {
                if parts[0] == format!("{}:{}", session.name, window.index) {
                    window.borders = Some(PaneBorders {
                        indicators: parts[1].into(),
                        style: parts[2].into(),
                        active_style: parts[3].into(),
                    });
                }
            }
        }
    }
}

fn parse_sessions(stdout: &str) -> Vec<Session> {
    let mut sessions: Vec<Session> = Vec::new();

    for line in stdout.lines() {
        let parts: Vec<&str> = line.splitn(15, '|').collect();
        if parts.len() != 15 {
            continue;
        }

        let session_name = parts[0].to_string();
        let session_attached = parts[1] == "1";
        let window_index: u32 = parts[2].parse().unwrap_or(0);
        let window_name = parts[3].to_string();
        let window_active = parts[4] == "1";
        let pane_index: u32 = parts[5].parse().unwrap_or(0);
        let pane_active = parts[6] == "1";
        let current_path = parts[14].to_string();
        let dimensions: Result<Vec<u32>, _> = parts[7..13].iter().map(|v| v.parse()).collect();
        let Ok(dimensions) = dimensions else { continue };
        let [left, top, width, height, window_width, window_height] = dimensions[..] else {
            continue;
        };
        if width == 0 || height == 0 || window_width == 0 || window_height == 0 {
            continue;
        }
        let zoomed = parts[13] == "1";

        let target = format!("{}:{}.{}", session_name, window_index, pane_index);

        let pane = Pane {
            index: pane_index,
            active: pane_active,
            target,
            current_path,
            geometry: PaneGeometry {
                left,
                top,
                width,
                height,
            },
        };

        let session = sessions.iter_mut().find(|s| s.name == session_name);
        match session {
            Some(session) => {
                let window = session.windows.iter_mut().find(|w| w.index == window_index);
                match window {
                    Some(window) => {
                        window.panes.push(pane);
                    }
                    None => {
                        session.windows.push(Window {
                            index: window_index,
                            name: window_name,
                            active: window_active,
                            panes: vec![pane],
                            width: window_width,
                            height: window_height,
                            zoomed,
                            borders: None,
                        });
                    }
                }
            }
            None => {
                sessions.push(Session {
                    name: session_name,
                    attached: session_attached,
                    windows: vec![Window {
                        index: window_index,
                        name: window_name,
                        active: window_active,
                        panes: vec![pane],
                        width: window_width,
                        height: window_height,
                        zoomed,
                        borders: None,
                    }],
                });
            }
        }
    }

    sessions
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires permission to start an isolated tmux server"]
    fn lists_real_split_resize_and_zoom_geometry() {
        let socket = format!("/tmp/reattach-layout-{}.sock", uuid::Uuid::new_v4());
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
            let result = Command::new("tmux")
                .args(["-S", &socket])
                .args(args)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
        };
        run(&[
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "layout",
            "-x",
            "141",
            "-y",
            "40",
            "sleep 60",
        ]);
        run(&[
            "set-option",
            "-gw",
            "pane-border-style",
            "fg=green,bg=black",
        ]);
        run(&[
            "set-option",
            "-w",
            "-t",
            "layout:0",
            "pane-active-border-style",
            "fg=#123456,bg=yellow",
        ]);
        run(&[
            "set-option",
            "-w",
            "-t",
            "layout:0",
            "pane-border-indicators",
            "off",
        ]);
        run(&["split-window", "-h", "-t", "layout:0.0", "sleep 60"]);
        run(&["split-window", "-v", "-t", "layout:0.1", "sleep 60"]);
        let sessions = list_sessions_at(Some(&socket)).unwrap();
        let window = &sessions[0].windows[0];
        let borders = window.borders.as_ref().unwrap();
        assert_eq!(borders.style, "fg=green,bg=black");
        assert_eq!(borders.active_style, "fg=#123456,bg=yellow");
        assert_eq!(borders.indicators, "off");
        run(&[
            "set-option",
            "-w",
            "-t",
            "layout:0",
            "pane-border-indicators",
            "colour",
        ]);
        assert_eq!(
            list_sessions_at(Some(&socket)).unwrap()[0].windows[0]
                .borders
                .as_ref()
                .unwrap()
                .indicators,
            "colour"
        );
        assert_eq!(window.panes.len(), 3);
        assert_eq!((window.width, window.height), (141, 40));
        assert_eq!(window.panes[0].geometry.height, 40);
        assert!(window.panes[2].geometry.top > window.panes[1].geometry.top);
        run(&["resize-window", "-t", "layout:0", "-x", "160", "-y", "50"]);
        let sessions = list_sessions_at(Some(&socket)).unwrap();
        assert_eq!(
            (sessions[0].windows[0].width, sessions[0].windows[0].height),
            (160, 50)
        );
        run(&["resize-pane", "-Z", "-t", "layout:0.2"]);
        let sessions = list_sessions_at(Some(&socket)).unwrap();
        assert!(sessions[0].windows[0].zoomed);
        assert_eq!(
            sessions[0].windows[0]
                .panes
                .iter()
                .filter(|p| p.active)
                .count(),
            1
        );
    }

    #[test]
    fn parses_mixed_split_geometry_and_paths_with_delimiters() {
        let sessions = parse_sessions(concat!(
            "work|1|0|editor|1|0|1|0|0|60|40|121|40|0|/tmp/a|b\n",
            "work|1|0|editor|1|1|0|61|0|60|19|121|40|0|/tmp\n",
            "work|1|0|editor|1|2|0|61|20|60|20|121|40|0|/tmp\n"
        ));
        let window = &sessions[0].windows[0];
        assert_eq!((window.width, window.height), (121, 40));
        assert_eq!(window.panes.len(), 3);
        assert_eq!(window.panes[0].current_path, "/tmp/a|b");
        assert_eq!(window.panes[2].target, "work:0.2");
        assert_eq!(
            (window.panes[2].geometry.left, window.panes[2].geometry.top),
            (61, 20)
        );
        assert!(!window.zoomed);
    }

    #[test]
    fn rejects_missing_or_invalid_geometry() {
        for row in [
            "bad",
            "s|0|0|w|1|0|1|0|0|0|24|80|24|0|/tmp",
            "s|0|0|w|1|0|1|x|0|80|24|80|24|0|/tmp",
        ] {
            assert!(parse_sessions(row).is_empty());
        }
        let sessions = parse_sessions("s|0|0|w|1|0|1|0|0|80|24|80|24|1|/tmp");
        assert!(sessions[0].windows[0].zoomed);
    }
}
