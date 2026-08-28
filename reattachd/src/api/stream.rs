use std::time::Duration;

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query,
    },
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::{Deserialize, Serialize};

use crate::tmux;

use super::output::{OutputQuery, MAX_LINES};

const CAPTURE_INTERVAL: Duration = Duration::from_millis(100);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMessage {
    Input { text: String },
    Escape,
    Refresh,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage {
    Output {
        output: String,
    },
    Patch {
        start_line: usize,
        delete_count: usize,
        lines: Vec<String>,
    },
    Error {
        error: String,
    },
}

pub async fn stream_pane(
    ws: WebSocketUpgrade,
    Path(target): Path<String>,
    Query(query): Query<OutputQuery>,
) -> Result<Response, StatusCode> {
    if query.lines > MAX_LINES {
        return Err(StatusCode::BAD_REQUEST);
    }

    Ok(ws
        .on_upgrade(move |socket| handle_socket(socket, target, query.lines))
        .into_response())
}

async fn handle_socket(mut socket: WebSocket, target: String, lines: u32) {
    let mut interval = tokio::time::interval(CAPTURE_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.tick().await;
    let mut last_output: Option<String> = None;

    loop {
        tokio::select! {
            _ = interval.tick() => {
                match capture_pane(target.clone(), lines).await {
                    Ok(output) if last_output.as_ref() != Some(&output) => {
                        let message = match &last_output {
                            Some(previous) => make_patch(previous, &output),
                            None => ServerMessage::Output {
                                output: output.clone(),
                            },
                        };
                        last_output = Some(output);
                        if send_message(&mut socket, &message).await.is_err() {
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        let _ = send_message(&mut socket, &ServerMessage::Error {
                            error: error.to_string(),
                        }).await;
                        break;
                    }
                }
            }
            _ = heartbeat.tick() => {
                if socket.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }
            message = socket.recv() => {
                let Some(message) = message else { break };
                let Ok(message) = message else { break };

                match message {
                    Message::Text(text) => {
                        let result = match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(ClientMessage::Input { text }) => {
                                let input_target = target.clone();
                                run_tmux(move || tmux::send_keys(&input_target, &text)).await
                            }
                            Ok(ClientMessage::Escape) => {
                                let escape_target = target.clone();
                                run_tmux(move || tmux::send_escape(&escape_target)).await
                            }
                            Ok(ClientMessage::Refresh) => {
                                last_output = None;
                                continue;
                            }
                            Err(error) => {
                                let _ = send_message(&mut socket, &ServerMessage::Error {
                                    error: format!("invalid message: {error}"),
                                }).await;
                                continue;
                            }
                        };

                        if let Err(error) = result {
                            let _ = send_message(&mut socket, &ServerMessage::Error {
                                error: error.to_string(),
                            }).await;
                        }
                    }
                    Message::Close(_) => break,
                    Message::Ping(payload) => {
                        if socket.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Message::Pong(_) | Message::Binary(_) => {}
                }
            }
        }
    }
}

fn make_patch(previous: &str, current: &str) -> ServerMessage {
    let previous_lines: Vec<&str> = previous.split('\n').collect();
    let current_lines: Vec<&str> = current.split('\n').collect();

    let prefix = previous_lines
        .iter()
        .zip(&current_lines)
        .take_while(|(old, new)| old == new)
        .count();

    let max_suffix = previous_lines
        .len()
        .min(current_lines.len())
        .saturating_sub(prefix);
    let suffix = (0..max_suffix)
        .take_while(|offset| {
            previous_lines[previous_lines.len() - 1 - offset]
                == current_lines[current_lines.len() - 1 - offset]
        })
        .count();

    ServerMessage::Patch {
        start_line: prefix,
        delete_count: previous_lines.len() - prefix - suffix,
        lines: current_lines[prefix..current_lines.len() - suffix]
            .iter()
            .map(|line| (*line).to_string())
            .collect(),
    }
}

async fn capture_pane(target: String, lines: u32) -> Result<String, tmux::TmuxError> {
    run_tmux(move || tmux::capture_pane(&target, lines)).await
}

async fn run_tmux<T, F>(operation: F) -> Result<T, tmux::TmuxError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, tmux::TmuxError> + Send + 'static,
{
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|error| tmux::TmuxError::Command(format!("tmux task failed: {error}")))?
}

async fn send_message(socket: &mut WebSocket, message: &ServerMessage) -> Result<(), ()> {
    let text = serde_json::to_string(message).map_err(|_| ())?;
    socket
        .send(Message::Text(text.into()))
        .await
        .map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_input_message() {
        let message =
            serde_json::from_str::<ClientMessage>(r#"{"type":"input","text":"cargo test"}"#)
                .expect("input message should parse");

        assert!(matches!(message, ClientMessage::Input { text } if text == "cargo test"));
    }

    #[test]
    fn serializes_output_message() {
        let json = serde_json::to_string(&ServerMessage::Output {
            output: "ready".to_string(),
        })
        .expect("output message should serialize");

        assert_eq!(json, r#"{"type":"output","output":"ready"}"#);
    }

    #[test]
    fn creates_minimal_line_patch() {
        let patch = make_patch("one\ntwo\nthree\n", "one\nchanged\nthree\n");

        assert!(matches!(
            patch,
            ServerMessage::Patch {
                start_line: 1,
                delete_count: 1,
                lines,
            } if lines == vec!["changed"]
        ));
    }

    #[test]
    fn line_patches_reconstruct_current_output() {
        let cases = [
            ("", "ready\n"),
            ("one\n", "one\ntwo\n"),
            ("one\ntwo\n", "two\n"),
            ("one\ntwo\nthree\n", "one\nreplacement\nfour\nthree\n"),
        ];

        for (previous, current) in cases {
            let ServerMessage::Patch {
                start_line,
                delete_count,
                lines,
            } = make_patch(previous, current)
            else {
                panic!("expected a patch");
            };

            let mut reconstructed: Vec<String> = previous.split('\n').map(str::to_string).collect();
            reconstructed.splice(start_line..start_line + delete_count, lines);
            assert_eq!(reconstructed.join("\n"), current);
        }
    }
}
