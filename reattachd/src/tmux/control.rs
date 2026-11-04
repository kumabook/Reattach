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

// Only this lease owns the temporary grouped session; never destroy its source.
struct PrivateSession {
    id: String,
    source: String,
    socket: Option<String>,
}

impl Drop for PrivateSession {
    fn drop(&mut self) {
        let id = self.id.clone();
        let socket = self.socket.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = command(socket.as_deref(), &["detach-client", "-s", &id]).await;
                let _ = command(socket.as_deref(), &["kill-session", "-t", &id]).await;
            });
        }
    }
}

// Each WebSocket owns its control client. Never send keys to a desktop client.
// Closing stdin / killing the child detaches only this client, not the session.
pub struct ControlClient {
    child: Child,
    name: String,
    socket: Option<String>,
    output: BufReader<ChildStdout>,
    private_session: Option<PrivateSession>,
    copied_text: Option<String>,
}

impl ControlClient {
    pub async fn attach(target: &str) -> Result<Self, TmuxError> {
        Self::attach_at(target, None).await
    }

    async fn attach_at(target: &str, socket: Option<String>) -> Result<Self, TmuxError> {
        Self::attach_client_at(target, socket, false).await
    }

    pub async fn attach_independent(target: &str) -> Result<Self, TmuxError> {
        Self::attach_independent_at(target, None).await
    }

    async fn attach_independent_at(
        target: &str,
        socket: Option<String>,
    ) -> Result<Self, TmuxError> {
        let sock = socket.as_deref();
        let source = command(
            sock,
            &["display-message", "-p", "-t", target, "#{session_id}"],
        )
        .await?
        .trim()
        .to_owned();
        let position = command(
            sock,
            &[
                "display-message",
                "-p",
                "-t",
                target,
                "#{window_index}.#{pane_index}",
            ],
        )
        .await?
        .trim()
        .to_owned();
        let name = format!("reattach-private-{}", uuid::Uuid::new_v4());
        let id = command(
            sock,
            &[
                "new-session",
                "-d",
                "-t",
                &source,
                "-s",
                &name,
                "-P",
                "-F",
                "#{session_id}",
            ],
        )
        .await?
        .trim()
        .to_owned();
        let lease = PrivateSession {
            id: id.clone(),
            source: source.clone(),
            socket: socket.clone(),
        };
        command(sock, &["set-option", "-t", &id, "@reattach_private", "1"]).await?;
        // tmux 3.6a can crash while automatically destroying a grouped session.
        // Explicitly detach clients before removing our session instead.
        command(
            sock,
            &["set-option", "-t", &id, "destroy-unattached", "off"],
        )
        .await?;
        for option in ["prefix", "prefix2", "key-table", "repeat-time"] {
            let value = command(sock, &["show-options", "-Aqv", "-t", &source, option]).await?;
            command(
                sock,
                &[
                    "set-option",
                    "-t",
                    &id,
                    option,
                    value.trim_end_matches('\n'),
                ],
            )
            .await?;
        }
        // attach-session -t pane changes the window's shared active pane before
        // active-pane isolation takes effect. Attach to the session first, then
        // select from inside our control client instead.
        let mut client = Self::attach_client_at(&name, socket.clone(), true).await?;
        let window = position
            .split('.')
            .next()
            .ok_or_else(|| TmuxError::Command("invalid window position".into()))?;
        client
            .execute(&format!("select-window -t '{name}:{window}'"))
            .await?;
        client
            .execute(&format!("select-pane -t '{name}:{position}'"))
            .await?;
        client.private_session = Some(lease);
        Ok(client)
    }

    async fn attach_client_at(
        target: &str,
        socket: Option<String>,
        independent: bool,
    ) -> Result<Self, TmuxError> {
        // Share tmux's active pane just like a normal terminal client. A private
        // active-pane would make app-side navigation disagree with the desktop.
        let mut child = tmux_command(socket.as_deref())
            .args([
                "-C",
                "attach-session",
                "-f",
                if independent {
                    "ignore-size,no-output,active-pane"
                } else {
                    "ignore-size,no-output"
                },
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
            private_session: None,
            copied_text: None,
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
        let mut state = self.raw_state().await?;
        if self.private_session.is_some() {
            let session = self.query("#{session_id}").await?;
            if self
                .private_session
                .as_ref()
                .is_some_and(|lease| lease.id != session)
            {
                // A custom binding switched sessions. Move our client into a new
                // private group before processing another key.
                let replacement =
                    Self::attach_independent_at(&state.target, self.socket.clone()).await?;
                *self = replacement;
                state = self.raw_state().await?;
            }
            let source = &self.private_session.as_ref().unwrap().source;
            let name = command(
                self.socket.as_deref(),
                &["display-message", "-p", "-t", source, "#{session_name}"],
            )
            .await?;
            let (_, position) = state
                .target
                .split_once(':')
                .ok_or_else(|| TmuxError::Command("invalid pane target".into()))?;
            state.target = format!("{}:{position}", name.trim_end_matches('\n'));
        }
        Ok(state)
    }

    async fn raw_state(&mut self) -> Result<ClientState, TmuxError> {
        let mut fields = Vec::new();
        for format in [
            "#{pane_id}",
            "#{client_key_table}",
            "#{prefix}",
            "#{session_name}:#{window_index}.#{pane_index}",
            "#{window_name}",
        ] {
            fields.push(self.query(format).await?);
        }
        ClientState::parse(&fields.join("\n"))
    }

    async fn query(&mut self, format: &str) -> Result<String, TmuxError> {
        self.execute(&format!("display-message -p '{}'", format))
            .await
    }

    // Commands here use fixed formats or tmux-generated identifiers only.
    async fn execute(&mut self, command: &str) -> Result<String, TmuxError> {
        self.child
            .stdin
            .as_mut()
            .ok_or_else(|| TmuxError::Command("tmux client closed".into()))?
            .write_all(format!("{command}\n").as_bytes())
            .await?;
        self.response(true).await
    }

    pub async fn reset_key_table(&self) -> Result<(), TmuxError> {
        command(
            self.socket.as_deref(),
            &["switch-client", "-c", &self.name, "-T", "root"],
        )
        .await?;
        Ok(())
    }

    async fn response(&mut self, control_only: bool) -> Result<String, TmuxError> {
        tokio::time::timeout(
            Duration::from_secs(3),
            read_response(&mut self.output, control_only),
        )
        .await
        .map_err(|_| TmuxError::Command("tmux control response timed out".into()))?
    }

    pub async fn send_text(&mut self, text: &str) -> Result<(), TmuxError> {
        if !text.is_empty() {
            let keys: Vec<String> = text.chars().map(|key| key.to_string()).collect();
            let clipboard = self.prepare_clipboard(&keys).await;
            command(
                self.socket.as_deref(),
                &["send-keys", "-K", "-c", &self.name, "-l", "--", text],
            )
            .await?;
            self.finish_clipboard(clipboard).await;
        }
        Ok(())
    }

    pub async fn send_key(
        &mut self,
        key: &str,
        modifiers: &[KeyModifier],
    ) -> Result<(), TmuxError> {
        let key = tmux_key_name(key, modifiers)?;
        let clipboard = self.prepare_clipboard(std::slice::from_ref(&key)).await;
        command(
            self.socket.as_deref(),
            &["send-keys", "-K", "-c", &self.name, "--", &key],
        )
        .await?;
        self.finish_clipboard(clipboard).await;
        Ok(())
    }
    pub fn take_copied_text(&mut self) -> Option<String> {
        self.copied_text.take()
    }

    // Only observe a copy binding dispatched by this connection. Do not sync
    // the server-global paste buffer on connect, navigation, or polling ticks.
    async fn prepare_clipboard(&mut self, keys: &[String]) -> Option<Option<String>> {
        let mode = self
            .query("#{pane_mode}|#{mode-keys}|#{client_key_table}")
            .await
            .ok()?;
        let mut fields = mode.split('|');
        if fields.next()? != "copy-mode" {
            return None;
        }
        let table = if fields.next()? == "vi" {
            "copy-mode-vi"
        } else {
            "copy-mode"
        };
        if fields.next()? != "root" {
            return None;
        }
        let bindings = command(self.socket.as_deref(), &["list-keys", "-T", table])
            .await
            .ok()?;
        for binding in bindings.lines() {
            let Some(key) = binding
                .split_whitespace()
                .skip_while(|part| *part != "-T")
                .nth(2)
            else {
                continue;
            };
            let key = key.trim_matches(['\'', '"']);
            if keys
                .iter()
                .any(|input| input == key || (input == " " && key == "Space"))
                && is_copy_binding(binding)
            {
                return self.latest_buffer_name().await.ok();
            }
        }
        None
    }

    async fn latest_buffer_name(&self) -> Result<Option<String>, TmuxError> {
        let buffers = command(
            self.socket.as_deref(),
            &["list-buffers", "-F", "#{buffer_name}"],
        )
        .await?;
        Ok(buffers.lines().next().map(str::to_owned))
    }

    async fn finish_clipboard(&mut self, before: Option<Option<String>>) {
        let Some(before) = before else {
            return;
        };
        let Ok(Some(name)) = self.latest_buffer_name().await else {
            return;
        };
        if before.as_ref() == Some(&name) {
            return;
        }
        if let Ok(text) = command(self.socket.as_deref(), &["save-buffer", "-b", &name, "-"]).await
        {
            self.copied_text = Some(text);
        }
    }
}

fn is_copy_binding(binding: &str) -> bool {
    binding.split_whitespace().any(|word| {
        let word = word.trim_matches(['\'', '"', ';', '{', '}']);
        matches!(
            word,
            "copy-selection"
                | "copy-selection-no-clear"
                | "copy-selection-and-cancel"
                | "copy-pipe"
                | "copy-pipe-no-clear"
                | "copy-pipe-and-cancel"
                | "copy-line"
                | "copy-line-and-cancel"
                | "copy-end-of-line"
                | "copy-end-of-line-and-cancel"
                | "copy-pipe-line"
                | "copy-pipe-line-and-cancel"
                | "copy-pipe-end-of-line"
                | "copy-pipe-end-of-line-and-cancel"
        )
    })
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

pub(super) async fn command(socket: Option<&str>, args: &[&str]) -> Result<String, TmuxError> {
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

    #[test]
    fn recognizes_custom_copy_bindings_but_not_movement_or_cancel() {
        assert!(is_copy_binding("bind-key -T copy-mode C-w send -X copy-pipe-and-cancel 'reattach-to-user-namespace pbcopy'"));
        assert!(is_copy_binding(
            "bind-key -T copy-mode-vi y send-keys -X copy-selection-no-clear"
        ));
        assert!(!is_copy_binding(
            "bind-key -T copy-mode C-g send-keys -X cancel"
        ));
        assert!(!is_copy_binding(
            "bind-key -T copy-mode Left send-keys -X cursor-left"
        ));
    }

    #[tokio::test]
    #[ignore = "requires permission to start an isolated tmux server"]
    async fn automatically_copies_custom_bindings_without_replaying_other_buffers() {
        let socket = format!("/tmp/reattach-auto-copy-{}.sock", uuid::Uuid::new_v4());
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
            &[
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "probe",
                "printf 'hello 日本語\\nnext line\\n'; sleep 60",
            ],
        )
        .await
        .unwrap();
        command(
            sock,
            &["set-option", "-w", "-t", "probe", "mode-keys", "emacs"],
        )
        .await
        .unwrap();
        command(
            sock,
            &[
                "bind-key",
                "-T",
                "copy-mode",
                "C-w",
                "send-keys",
                "-X",
                "copy-pipe-and-cancel",
                "cat >/dev/null",
            ],
        )
        .await
        .unwrap();
        command(
            sock,
            &[
                "bind-key",
                "-T",
                "copy-mode",
                "C-g",
                "send-keys",
                "-X",
                "cancel",
            ],
        )
        .await
        .unwrap();
        let mut client = ControlClient::attach_at("probe", Some(socket.clone()))
            .await
            .unwrap();
        assert!(client.take_copied_text().is_none());
        tokio::time::sleep(Duration::from_millis(100)).await;
        async fn select(socket: &str) {
            let sock = Some(socket);
            command(sock, &["copy-mode", "-t", "probe"]).await.unwrap();
            for action in [
                "history-top",
                "start-of-line",
                "begin-selection",
                "cursor-down",
                "end-of-line",
            ] {
                command(sock, &["send-keys", "-t", "probe", "-X", action])
                    .await
                    .unwrap();
            }
        }
        for _ in 0..2 {
            select(&socket).await;
            client.send_key("w", &[KeyModifier::Control]).await.unwrap();
            assert_eq!(
                client.take_copied_text().as_deref(),
                Some("hello 日本語\nnext line")
            );
            assert!(client.take_copied_text().is_none());
        }
        select(&socket).await;
        command(
            sock,
            &["set-buffer", "-b", "other-client", "unrelated copy"],
        )
        .await
        .unwrap();
        client.state().await.unwrap();
        assert!(client.take_copied_text().is_none());
        client.send_key("left", &[]).await.unwrap();
        assert!(client.take_copied_text().is_none());
        client.send_key("g", &[KeyModifier::Control]).await.unwrap();
        assert!(client.take_copied_text().is_none());
        command(
            sock,
            &["set-option", "-w", "-t", "probe", "mode-keys", "vi"],
        )
        .await
        .unwrap();
        command(
            sock,
            &[
                "bind-key",
                "-T",
                "copy-mode-vi",
                "y",
                "send-keys",
                "-X",
                "copy-selection-no-clear",
            ],
        )
        .await
        .unwrap();
        select(&socket).await;
        client.send_text("y").await.unwrap();
        assert_eq!(
            client.take_copied_text().as_deref(),
            Some("hello 日本語\nnext line\n")
        );
        assert_eq!(client.query("#{pane_mode}").await.unwrap(), "copy-mode");
        drop(client);
        let mut reconnected = ControlClient::attach_at("probe", Some(socket.clone()))
            .await
            .unwrap();
        reconnected.state().await.unwrap();
        assert!(reconnected.take_copied_text().is_none());
    }

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
            &super::super::create::window_args(&format!("{}:", session.trim()), "/tmp", false),
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
    #[ignore = "requires permission to start an isolated tmux server"]
    async fn independent_selection_shares_content_without_moving_desktop() {
        let socket = format!("/tmp/reattach-independent-{}.sock", uuid::Uuid::new_v4());
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
        command(sock, &["split-window", "-d", "-t", "probe:0", "cat"])
            .await
            .unwrap();
        command(sock, &["new-window", "-d", "-t", "probe", "cat"])
            .await
            .unwrap();
        let desktop = command(
            sock,
            &["display-message", "-p", "-t", "probe", "#{pane_id}"],
        )
        .await
        .unwrap();
        let mut client = ControlClient::attach_independent_at("probe:0.1", Some(socket.clone()))
            .await
            .unwrap();
        let lease_id = client.private_session.as_ref().unwrap().id.clone();
        let initial = client.state().await.unwrap();
        assert_eq!(initial.target, "probe:0.1");
        assert_eq!(initial.prefix, "C-j");
        assert_eq!(
            command(
                sock,
                &["display-message", "-p", "-t", "probe", "#{pane_id}"]
            )
            .await
            .unwrap(),
            desktop
        );
        client.send_key("j", &[KeyModifier::Control]).await.unwrap();
        client.send_text("n").await.unwrap();
        let next = client.state().await.unwrap();
        assert_eq!(next.target, "probe:1.0");
        assert_eq!(
            command(
                sock,
                &["display-message", "-p", "-t", "probe", "#{pane_id}"]
            )
            .await
            .unwrap(),
            desktop
        );
        let mut other = ControlClient::attach_independent_at("probe:0.0", Some(socket.clone()))
            .await
            .unwrap();
        assert_eq!(other.state().await.unwrap().target, "probe:0.0");
        assert_eq!(client.state().await.unwrap().target, "probe:1.0");
        client.send_text("日本語").await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(command(sock, &["capture-pane", "-p", "-t", "probe:1.0"])
            .await
            .unwrap()
            .contains("日本語"));
        let visible = command(
            sock,
            &[
                "list-panes",
                "-a",
                "-f",
                "#{!=:#{@reattach_private},1}",
                "-F",
                "#{session_name}",
            ],
        )
        .await
        .unwrap();
        assert!(visible.lines().all(|line| line == "probe"));
        drop(other);
        drop(client);
        for _ in 0..40 {
            let sessions = command(sock, &["list-sessions", "-F", "#{session_id}"])
                .await
                .unwrap();
            if !sessions.lines().any(|id| id == lease_id) {
                assert_eq!(
                    command(
                        sock,
                        &["display-message", "-p", "-t", "probe", "#{pane_id}"]
                    )
                    .await
                    .unwrap(),
                    desktop
                );
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("private session leaked");
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
