use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdout, Command};

use super::{send::tmux_key_name, KeyModifier, TmuxError};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ClientState {
    pub pane_id: String,
    pub key_table: String,
    pub prefix: String,
    pub target: String,
    pub window_name: String,
}

impl ClientState {
    fn parse(value: &str) -> Result<Self, TmuxError> {
        let fields: Vec<_> = value.trim_end_matches('\n').splitn(5, '\n').collect();
        if fields.len() != 5
            || !fields[0].starts_with('%')
            || fields[0][1..].parse::<u64>().is_err()
        {
            return Err(TmuxError::Command("invalid tmux client state".into()));
        }
        Ok(Self {
            pane_id: fields[0].into(),
            key_table: fields[1].into(),
            prefix: fields[2].into(),
            target: fields[3].into(),
            window_name: fields[4].into(),
        })
    }
}

// Each WebSocket owns its control client. Never send keys to a desktop client.
// Closing stdin / killing the child detaches only this client, not the session.
pub struct ControlClient {
    child: Child,
    name: String,
    socket: Option<String>,
    output: BufReader<ChildStdout>,
}

impl ControlClient {
    pub async fn attach(target: &str) -> Result<Self, TmuxError> {
        Self::attach_at(target, None).await
    }

    async fn attach_at(target: &str, socket: Option<String>) -> Result<Self, TmuxError> {
        // Share tmux's active pane just like a normal terminal client. A private
        // active-pane would make app-side navigation disagree with the desktop.
        let mut child = tmux_command(socket.as_deref())
            .args([
                "-C",
                "attach-session",
                "-f",
                "ignore-size,no-output",
                "-t",
                target,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        let pid = child
            .id()
            .ok_or_else(|| TmuxError::Command("tmux client exited".into()))?;
        let output = BufReader::new(child.stdout.take().expect("piped tmux stdout"));
        let mut client = Self {
            output,
            child,
            name: String::new(),
            socket,
        };
        client.response(false).await?; // initial attach command response
        for _ in 0..40 {
            if client.child.try_wait()?.is_some() {
                return Err(TmuxError::Command(
                    "could not attach tmux control client".into(),
                ));
            }
            let clients = command(
                client.socket.as_deref(),
                &["list-clients", "-F", "#{client_pid}|#{client_name}"],
            )
            .await?;
            if let Some(name) = clients.lines().find_map(|line| {
                let (value, name) = line.split_once('|')?;
                (value == pid.to_string()).then(|| name.to_owned())
            }) {
                client.name = name;
                return Ok(client);
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        Err(TmuxError::Command(
            "timed out attaching tmux control client".into(),
        ))
    }

    // Query on the control connection itself: display-message -c only changes
    // format client variables, not the command's target pane/session.
    pub async fn state(&mut self) -> Result<ClientState, TmuxError> {
        let mut fields = Vec::new();
        for format in [
            "#{pane_id}",
            "#{client_key_table}",
            "#{prefix}",
            "#{session_name}:#{window_index}.#{pane_index}",
            "#{window_name}",
        ] {
            let command = format!("display-message -p '{}'\n", format);
            self.child
                .stdin
                .as_mut()
                .ok_or_else(|| TmuxError::Command("tmux client closed".into()))?
                .write_all(command.as_bytes())
                .await?;
            fields.push(self.response(true).await?);
        }
        ClientState::parse(&fields.join("\n"))
    }

    async fn response(&mut self, control_only: bool) -> Result<String, TmuxError> {
        tokio::time::timeout(
            Duration::from_secs(3),
            read_response(&mut self.output, control_only),
        )
        .await
        .map_err(|_| TmuxError::Command("tmux control response timed out".into()))?
    }

    pub async fn send_text(&self, text: &str) -> Result<(), TmuxError> {
        if !text.is_empty() {
            command(
                self.socket.as_deref(),
                &["send-keys", "-K", "-c", &self.name, "-l", "--", text],
            )
            .await?;
        }
        Ok(())
    }

    pub async fn send_key(&self, key: &str, modifiers: &[KeyModifier]) -> Result<(), TmuxError> {
        let key = tmux_key_name(key, modifiers)?;
        command(
            self.socket.as_deref(),
            &["send-keys", "-K", "-c", &self.name, "--", &key],
        )
        .await?;
        Ok(())
    }
}

async fn read_response<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    control_only: bool,
) -> Result<String, TmuxError> {
    let mut marker: Option<String> = None;
    let mut result = Vec::new();
    let mut capture = true;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).await? == 0 {
            return Err(TmuxError::Command(
                "tmux control client disconnected".into(),
            ));
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if let Some(id) = &marker {
            if line == format!("%end {id}") {
                if capture {
                    return Ok(result.join("\n"));
                }
                marker = None;
                result.clear();
                continue;
            }
            if line == format!("%error {id}") {
                if capture {
                    return Err(TmuxError::Command(result.join("\n")));
                }
                marker = None;
                result.clear();
                continue;
            }
            result.push(line.to_owned());
        } else if let Some(id) = line.strip_prefix("%begin ") {
            // Flag 1 identifies commands sent over this control connection.
            // Key bindings may emit unrelated flag-0 blocks between queries.
            capture = !control_only || id.split_whitespace().last() == Some("1");
            marker = Some(id.to_owned());
        } else if line.starts_with("%exit") {
            return Err(TmuxError::Command("tmux control client detached".into()));
        }
        // Notifications outside response blocks are consumed, never displayed.
    }
}

fn tmux_command(socket: Option<&str>) -> Command {
    let mut command = Command::new("tmux");
    if let Some(socket) = socket {
        command.args(["-S", socket]);
    }
    command
}

async fn command(socket: Option<&str>, args: &[&str]) -> Result<String, TmuxError> {
    let output = tokio::time::timeout(
        Duration::from_secs(3),
        tmux_command(socket).args(args).kill_on_drop(true).output(),
    )
    .await
    .map_err(|_| TmuxError::Command("tmux client command timed out".into()))??;
    if !output.status.success() {
        return Err(TmuxError::Command(
            String::from_utf8_lossy(&output.stderr).trim().into(),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Explicitly opt in: this starts a disposable tmux server on its own socket.
    #[tokio::test]
    #[ignore = "requires permission to start an isolated tmux server"]
    async fn native_prefix_navigation_text_and_cleanup() {
        let socket = format!("/tmp/reattach-prefix-{}.sock", uuid::Uuid::new_v4());
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::process::Command::new("tmux")
                    .args(["-S", &self.0, "kill-server"])
                    .output();
            }
        }
        let _cleanup = Cleanup(socket.clone());
        let sock = Some(socket.as_str());
        command(
            sock,
            &["-f", "/dev/null", "new-session", "-d", "-s", "probe", "cat"],
        )
        .await
        .unwrap();
        command(sock, &["set-option", "-t", "probe", "prefix", "C-j"])
            .await
            .unwrap();
        command(
            sock,
            &["bind-key", "-T", "prefix", "q", "split-window", "-h", "cat"],
        )
        .await
        .unwrap();
        let mut client = ControlClient::attach_at("probe:0.0", Some(socket.clone()))
            .await
            .unwrap();
        let first = client.state().await.unwrap();
        assert_eq!(first.prefix, "C-j");
        command(sock, &["new-session", "-d", "-s", "other", "cat"])
            .await
            .unwrap();
        let mut other = ControlClient::attach_at("other", Some(socket.clone()))
            .await
            .unwrap();
        assert_eq!(client.state().await.unwrap().pane_id, first.pane_id);
        assert_ne!(other.state().await.unwrap().pane_id, first.pane_id);
        drop(other);
        client.send_key("j", &[KeyModifier::Control]).await.unwrap();
        assert_eq!(client.state().await.unwrap().key_table, "prefix");
        client.send_text("q").await.unwrap();
        let second = client.state().await.unwrap();
        assert_ne!(first.pane_id, second.pane_id);
        assert_eq!(second.key_table, "root");
        client.send_text("日本語 Enter - hello").await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let output = command(sock, &["capture-pane", "-p", "-t", &second.pane_id])
            .await
            .unwrap();
        assert!(output.contains("日本語 Enter - hello"), "{output:?}");
        client.send_key("j", &[KeyModifier::Control]).await.unwrap();
        client.send_text("o").await.unwrap();
        assert_eq!(client.state().await.unwrap().pane_id, first.pane_id);
        assert_eq!(
            command(
                sock,
                &["display-message", "-p", "-t", "probe", "#{pane_id}"]
            )
            .await
            .unwrap()
            .trim(),
            first.pane_id
        );
        command(
            sock,
            &["new-window", "-d", "-t", "probe", "-n", "second", "cat"],
        )
        .await
        .unwrap();
        client.send_key("j", &[KeyModifier::Control]).await.unwrap();
        client.send_text("n").await.unwrap();
        let next_window = client.state().await.unwrap();
        assert_eq!(next_window.window_name, "second");
        assert_ne!(next_window.pane_id, first.pane_id);
        drop(client);
        // Ctrl-Tab / sidebar selection opens a stream for the chosen pane.
        // Reattaching must update the shared window and pane, not just our view.
        for selected in [&first, &second, &next_window] {
            let mut switched = ControlClient::attach_at(&selected.target, Some(socket.clone()))
                .await
                .unwrap();
            assert_eq!(switched.state().await.unwrap().pane_id, selected.pane_id);
            assert_eq!(
                command(
                    sock,
                    &["display-message", "-p", "-t", "probe", "#{pane_id}"]
                )
                .await
                .unwrap()
                .trim(),
                selected.pane_id
            );
            // Desktop-side selection must also be reflected by the app client.
            command(sock, &["select-window", "-t", &first.target])
                .await
                .unwrap();
            command(sock, &["select-pane", "-t", &first.pane_id])
                .await
                .unwrap();
            assert_eq!(switched.state().await.unwrap().pane_id, first.pane_id);
            drop(switched);
        }
        // The explicit selection API works without a control client (compose mode).
        command(sock, &super::super::select::selection_args(&second.target))
            .await
            .unwrap();
        assert_eq!(
            command(
                sock,
                &["display-message", "-p", "-t", "probe", "#{pane_id}"]
            )
            .await
            .unwrap()
            .trim(),
            second.pane_id
        );
        let session = command(
            sock,
            &["display-message", "-p", "-t", "probe", "#{session_id}"],
        )
        .await
        .unwrap();
        let created = command(
            sock,
            &super::super::create::window_args(&format!("{}:", session.trim()), "/tmp"),
        )
        .await
        .unwrap();
        let selected = command(
            sock,
            &[
                "display-message",
                "-p",
                "-t",
                "probe",
                "#{session_name}:#{window_index}.#{pane_index}",
            ],
        )
        .await
        .unwrap();
        assert_eq!(created.trim(), selected.trim());
        assert!(created.starts_with("probe:"));
        for _ in 0..40 {
            if command(sock, &["list-clients"]).await.unwrap().is_empty() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("control client leaked after disconnect");
    }

    #[tokio::test]
    async fn control_responses_skip_notifications_and_key_binding_blocks() {
        let data =
            b"%window-add @1\n%begin 1 2 0\nignored\n%end 1 2 0\n%begin 1 3 1\n%12\n%end 1 3 1\n";
        let mut reader = &data[..];
        assert_eq!(read_response(&mut reader, true).await.unwrap(), "%12");
        assert!(read_response(&mut reader, true).await.is_err());
        let mut error = &b"%begin 1 4 1\nno such pane\n%error 1 4 1\n"[..];
        assert!(read_response(&mut error, true).await.is_err());
    }

    #[test]
    fn parses_client_navigation_and_custom_prefix() {
        let state = ClientState::parse("%12\nprefix\nC-j\nwork:2.1\neditor|notes\n").unwrap();
        assert_eq!(state.pane_id, "%12");
        assert_eq!(state.key_table, "prefix");
        assert_eq!(state.prefix, "C-j");
        assert_eq!(state.target, "work:2.1");
        assert_eq!(state.window_name, "editor|notes");
        assert!(ClientState::parse("\nroot\nC-b\nwork:0.0\nwindow").is_err());
        assert!(ClientState::parse("%1\nroot").is_err());
    }
}
