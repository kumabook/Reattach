use std::{process::Stdio, time::Duration};

use axum::{
    extract::{
        ws::{Message, WebSocket},
        WebSocketUpgrade,
    },
    response::Response,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
};

// Subscribe to all sessions, not just the session the observer attaches to.
// tmux evaluates subscriptions internally and emits only changed values.
const SUBSCRIPTION: &str = "refresh-client -B 'reattach-sessions::#{S:#{session_id}/#{session_name}/#{W:#{window_id}/#{window_index}/#{window_name}/#{window_active}/#{P:#{pane_id}/#{pane_index}/#{pane_active}/#{pane_current_path};}}}'\n";
const CHANGED: &str = r#"{"type":"sessions_changed"}"#;

pub async fn stream_sessions(ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(handle_socket)
}

fn changed(line: &str) -> bool {
    line.starts_with("%subscription-changed reattach-sessions ")
}

async fn handle_socket(mut socket: WebSocket) {
    // Each foreground subscription owns a read-only control client. Attaching
    // to a session (without a pane target) preserves its selected window/pane.
    // Closing the WebSocket drops the child and releases the observer.
    let mut heartbeat = tokio::time::interval(Duration::from_secs(20));
    let mut last_received = tokio::time::Instant::now();
    if socket.send(Message::Text(CHANGED.into())).await.is_err() {
        return;
    }
    loop {
        let child = Command::new("tmux")
            .args([
                "-C",
                "attach-session",
                "-f",
                "ignore-size,no-output,read-only",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn();
        if let Ok(mut child) = child {
            let mut input = child.stdin.take().expect("piped stdin");
            let mut lines = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
            if input.write_all(SUBSCRIPTION.as_bytes()).await.is_ok() {
                let mut attached = false;
                loop {
                    tokio::select! {
                        line = lines.next_line() => {
                            match line {
                                Ok(Some(line)) if changed(&line) => {
                                    if socket.send(Message::Text(CHANGED.into())).await.is_err() { return; }
                                }
                                Ok(Some(line)) if line.starts_with("%end") && !attached => {
                                    attached = true;
                                    if socket.send(Message::Text(CHANGED.into())).await.is_err() { return; }
                                }
                                Ok(Some(line)) if line.starts_with("%exit") => break,
                                Ok(Some(_)) => {},
                                _ => break,
                            }
                        }
                        message = socket.recv() => {
                            match message {
                                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                                _ => last_received = tokio::time::Instant::now(),
                            }
                        }
                        _ = heartbeat.tick() => {
                            if last_received.elapsed() > Duration::from_secs(60) { return; }
                            if socket.send(Message::Ping(vec![].into())).await.is_err() { return; }
                        }
                    }
                }
                if attached && socket.send(Message::Text(CHANGED.into())).await.is_err() {
                    return;
                }
            }
        }
        // No tmux server/session, or it restarted. Retry attaching; do not
        // repeatedly fetch the session list while nothing has changed.
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(5)) => {},
            message = socket.recv() => {
                if matches!(message, None | Some(Err(_)) | Some(Ok(Message::Close(_)))) { return; }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Server(String);
    impl Drop for Server {
        fn drop(&mut self) {
            let _ = std::process::Command::new("tmux")
                .args(["-S", &self.0, "kill-server"])
                .output();
        }
    }

    async fn run(server: &Server, args: &[&str]) -> String {
        let output = Command::new("tmux")
            .args(["-S", &server.0])
            .args(args)
            .output()
            .await
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }

    async fn next_change(
        lines: &mut tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    ) -> String {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let line = lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("control client exited");
                assert!(!line.starts_with("%error"), "{line}");
                if changed(&line) {
                    return line;
                }
            }
        })
        .await
        .expect("missing subscription notification")
    }

    #[tokio::test]
    #[ignore = "requires a local tmux socket"]
    async fn subscription_tracks_other_sessions_without_changing_selection() {
        let server = Server(format!(
            "/tmp/reattach-events-{}.sock",
            uuid::Uuid::new_v4()
        ));
        run(
            &server,
            &["-f", "/dev/null", "new-session", "-d", "-s", "one"],
        )
        .await;
        run(&server, &["new-session", "-d", "-s", "two"]).await;
        let before = run(
            &server,
            &[
                "display-message",
                "-p",
                "-t",
                "one",
                "#{window_id}/#{pane_id}",
            ],
        )
        .await;
        let mut child = Command::new("tmux")
            .args([
                "-S",
                &server.0,
                "-C",
                "attach-session",
                "-f",
                "ignore-size,no-output,read-only",
                "-t",
                "one",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(SUBSCRIPTION.as_bytes())
            .await
            .unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        next_change(&mut lines).await;
        assert_eq!(
            before,
            run(
                &server,
                &[
                    "display-message",
                    "-p",
                    "-t",
                    "one",
                    "#{window_id}/#{pane_id}"
                ]
            )
            .await
        );
        let pane = run(
            &server,
            &[
                "split-window",
                "-d",
                "-t",
                "two:0",
                "-P",
                "-F",
                "#{pane_id}",
            ],
        )
        .await;
        assert!(next_change(&mut lines).await.contains(&pane));
        run(&server, &["kill-pane", "-t", &pane]).await;
        assert!(!next_change(&mut lines).await.contains(&pane));
        run(&server, &["rename-window", "-t", "two:0", "renamed"]).await;
        assert!(next_change(&mut lines).await.contains("renamed"));
        assert!(
            tokio::time::timeout(Duration::from_millis(1500), next_change(&mut lines))
                .await
                .is_err()
        );
        child.kill().await.unwrap();
        child.wait().await.unwrap();
    }
}
