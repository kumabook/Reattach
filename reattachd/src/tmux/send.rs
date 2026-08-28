use std::{process::Command, thread, time::Duration};

use serde::Deserialize;

use crate::tmux::TmuxError;

const SUBMIT_DELAY: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum KeyModifier {
    Control,
    Alt,
    Shift,
}

pub fn send_keys(target: &str, text: &str) -> Result<(), TmuxError> {
    send_text(target, text)?;

    // Keep the submit key out of terminal applications' rapid-input/paste
    // detection so that it is consistently handled as Enter.
    thread::sleep(SUBMIT_DELAY);

    send_key(target, "enter", &[])
}

pub fn send_text(target: &str, text: &str) -> Result<(), TmuxError> {
    if text.is_empty() {
        return Ok(());
    }

    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, "-l", text])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}

pub fn send_key(target: &str, key: &str, modifiers: &[KeyModifier]) -> Result<(), TmuxError> {
    let key_name = tmux_key_name(key, modifiers)?;
    let output = Command::new("tmux")
        .args(["send-keys", "-t", target, &key_name])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TmuxError::Command(stderr.to_string()));
    }

    Ok(())
}

pub fn send_escape(target: &str) -> Result<(), TmuxError> {
    send_key(target, "escape", &[])
}

fn tmux_key_name(key: &str, modifiers: &[KeyModifier]) -> Result<String, TmuxError> {
    let base = match key {
        "enter" => "Enter".to_string(),
        "escape" => "Escape".to_string(),
        "tab" => "Tab".to_string(),
        "back_tab" => "BTab".to_string(),
        "backspace" => "BSpace".to_string(),
        "delete" => "DC".to_string(),
        "up" => "Up".to_string(),
        "down" => "Down".to_string(),
        "left" => "Left".to_string(),
        "right" => "Right".to_string(),
        "home" => "Home".to_string(),
        "end" => "End".to_string(),
        "page_up" => "PPage".to_string(),
        "page_down" => "NPage".to_string(),
        "space" => "Space".to_string(),
        character
            if !modifiers.is_empty()
                && character.chars().count() == 1
                && character.chars().all(|value| value.is_ascii_graphic()) =>
        {
            character.to_string()
        }
        _ => {
            return Err(TmuxError::Command(format!(
                "unsupported terminal key: {key}"
            )))
        }
    };

    let mut name = String::new();
    if modifiers.contains(&KeyModifier::Control) {
        name.push_str("C-");
    }
    if modifiers.contains(&KeyModifier::Alt) {
        name.push_str("M-");
    }
    if modifiers.contains(&KeyModifier::Shift) {
        name.push_str("S-");
    }
    name.push_str(&base);

    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_named_keys_for_tmux() {
        assert_eq!(tmux_key_name("enter", &[]).unwrap(), "Enter");
        assert_eq!(
            tmux_key_name("left", &[KeyModifier::Control, KeyModifier::Shift]).unwrap(),
            "C-S-Left"
        );
        assert_eq!(tmux_key_name("page_up", &[]).unwrap(), "PPage");
    }

    #[test]
    fn formats_modified_character_keys_for_tmux() {
        assert_eq!(tmux_key_name("c", &[KeyModifier::Control]).unwrap(), "C-c");
        assert_eq!(tmux_key_name("x", &[KeyModifier::Alt]).unwrap(), "M-x");
    }

    #[test]
    fn rejects_unknown_or_unmodified_character_keys() {
        assert!(tmux_key_name("unknown", &[]).is_err());
        assert!(tmux_key_name("a", &[]).is_err());
    }
}
