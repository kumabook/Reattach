mod capture;
mod create;
mod kill;
mod list;
mod send;

pub use capture::{capture_pane, capture_pane_snapshot, PaneCursor, PaneSnapshot};
pub use create::create_session;
pub use kill::kill_pane;
pub use list::list_sessions;
pub use send::{send_escape, send_key, send_keys, send_text, KeyModifier};

#[derive(Debug, thiserror::Error)]
pub enum TmuxError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("tmux command failed: {0}")]
    Command(String),
}
