use serde::Serialize;
use std::process::Command;

use crate::tmux::TmuxError;

#[derive(Debug, Serialize)]
pub struct Pane {
    pub index: u32,
    pub active: bool,
    pub target: String,
    pub current_path: String,
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: Vec<Pane>,
}

#[derive(Debug, Serialize)]
pub struct Session {
    pub name: String,
    pub attached: bool,
    pub windows: Vec<Window>,
}

pub fn list_sessions() -> Result<Vec<Session>, TmuxError> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}|#{session_attached}|#{window_index}|#{window_name}|#{window_active}|#{pane_index}|#{pane_active}|#{pane_current_path}",
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("no server running") || stderr.contains("no sessions") {
            return Ok(vec![]);
        }
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut sessions: Vec<Session> = Vec::new();

    for line in stdout.lines() {
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() != 8 {
            continue;
        }

        let session_name = parts[0].to_string();
        let session_attached = parts[1] == "1";
        let window_index: u32 = parts[2].parse().unwrap_or(0);
        let window_name = parts[3].to_string();
        let window_active = parts[4] == "1";
        let pane_index: u32 = parts[5].parse().unwrap_or(0);
        let pane_active = parts[6] == "1";
        let current_path = parts[7].to_string();

        let target = format!("{}:{}.{}", session_name, window_index, pane_index);

        let pane = Pane {
            index: pane_index,
            active: pane_active,
            target,
            current_path,
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
                    }],
                });
            }
        }
    }

    Ok(sessions)
}
