use super::{control::command, TmuxError};

pub async fn copy_selection(target: &str) -> Result<String, TmuxError> {
    copy_selection_at(None, target).await
}

async fn copy_selection_at(socket: Option<&str>, target: &str) -> Result<String, TmuxError> {
    let prefix = format!("reattach-copy-{}-", uuid::Uuid::new_v4());
    // A unique buffer prevents returning someone else's previous copy when
    // there is no active selection. Leave the selection and host clipboard alone.
    command(
        socket,
        &[
            "send-keys",
            "-t",
            target,
            "-X",
            "copy-selection-no-clear",
            "-C",
            &prefix,
        ],
    )
    .await?;
    let buffers = command(socket, &["list-buffers", "-F", "#{buffer_name}"]).await?;
    let name = buffers
        .lines()
        .find(|name| name.starts_with(&prefix))
        .ok_or_else(|| TmuxError::Command("tmux のコピーモードで文字を選択してください".into()))?;
    let text = command(socket, &["save-buffer", "-b", name, "-"]).await;
    let _ = command(socket, &["delete-buffer", "-b", name]).await;
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "requires permission to start an isolated tmux server"]
    async fn copies_only_current_selection_and_preserves_buffers() {
        let socket = format!("/tmp/reattach-copy-{}.sock", uuid::Uuid::new_v4());
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
        command(sock, &["set-buffer", "-b", "existing", "previous"])
            .await
            .unwrap();
        assert!(copy_selection_at(sock, "probe").await.is_err());
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
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
        assert_eq!(
            copy_selection_at(sock, "probe").await.unwrap().trim_end(),
            "hello 日本語\nnext line"
        );
        assert_eq!(
            command(sock, &["show-buffer", "-b", "existing"])
                .await
                .unwrap(),
            "previous"
        );
        assert_eq!(
            command(sock, &["list-buffers", "-F", "#{buffer_name}"])
                .await
                .unwrap()
                .trim(),
            "existing"
        );
    }
}
