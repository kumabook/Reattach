# Changelog

## 2.0.2 — Daemon released 2026-11-11

- Preserve a newly registered permission request when an earlier screen check finishes. Each registration has a unique generation, so repeated requests for the same command in the same second are not removed by a stale check.
- No iOS app update is required for this fix.

## 2.0.1 — Daemon released 2026-11-10; iOS 2.0.0 awaiting review

### Daemon

- Add an API to split a pane left and right or top and bottom, and advertise it on pane streams so the app shows split actions only when the daemon supports them.
- Clear a pending coding-agent request once its prompt has left the pane, such as after a denial, an interruption, or an approved tool that is still running.
- Detect visible Codex command approvals even when a lifecycle hook was missed.

### iOS

- Split the selected pane from the display-mode menu while the tmux layout is shown.
- Create a window without a selected pane, and close the permission inbox once every request has been answered.

## 2.0.0 — Daemon released 2026-11-08; iOS awaiting review

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
