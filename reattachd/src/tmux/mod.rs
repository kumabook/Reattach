mod capture;
mod clipboard;
mod control;
mod create;
mod kill;
mod list;
mod select;
mod send;

pub use capture::{capture_pane, capture_pane_snapshot, PaneCursor, PaneSnapshot};
pub use clipboard::copy_selection;
pub use control::{ClientState, ControlClient};
pub use create::{create_session, create_window, split_pane, SplitDirection};
pub use kill::kill_pane;
pub use list::{list_sessions, PaneBorders, PaneGeometry};
pub use select::select_pane;
pub use send::{send_escape, send_key, send_keys, send_text, KeyModifier};

#[derive(Debug, thiserror::Error)]
pub enum TmuxError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("tmux command failed: {0}")]
    Command(String),
}
