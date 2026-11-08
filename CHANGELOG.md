# Changelog

## 2.0.0 — Unreleased

### iOS

- Reproduce horizontal, vertical, and mixed tmux pane layouts; scroll panes independently and choose between the selected pane and the tmux layout.

- Follow the configured tmux prefix and copy-mode key bindings through a dedicated tmux client.
- Display the copy-mode viewport, cursor, and selection, including scrolled and rectangular selections.
- Copy text confirmed from the app to the iOS clipboard; add a selection-copy menu, paste controls, and terminal links.
- Reconnect interrupted WebSocket streams, show slow-response and reconnecting indicators, and discard stale queued direct input after a disconnect.
- Choose synchronized or independent pane navigation and restore the last selected pane.
- Improve Japanese composition, hardware keyboard navigation, text-size controls, and Unicode cursor alignment.
- Show permission-waiting panes and filter non-actionable coding-agent notifications.
- Localize the interface, accessibility descriptions, errors, and camera permission prompt in English and Japanese.

### Daemon

- Include pane geometry, window dimensions, zoom state, and effective pane border settings in the session API.

- Add clipboard messages and copy-mode cursor/selection metadata to pane streams.
- Respect tmux key bindings when detecting copy confirmation from the app.
- Improve stream timeouts, pane/session events, and independent client selection.

### Upgrading

Update both the app and `reattachd` to 2.0.0 for the new tmux and clipboard features. Reattach uses your tmux configuration; it does not replace your key bindings. Automatic clipboard transfer follows copy bindings that create a tmux paste buffer. Custom asynchronous scripts or bindings that suppress that buffer may require the app's selection-copy menu.

This release improves connection recovery; it does not claim to fix the separately observed tmux server crash.
