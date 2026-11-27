# Changelog

## 2.1.0 — Daemon release in preparation; iOS, watchOS and Mac 2.1.0 in preparation

### Daemon

- Add `reattachd init`, which sets up a computer in one command: it detects Tailscale (or takes `--url` for Cloudflare Tunnel and other HTTPS proxies), installs a LaunchAgent on macOS or a systemd user service on Linux, offers to install the Claude Code and Codex hooks, connects Reattach for Mac on the same Mac, and shows the pairing QR code. `reattachd setup` then works without `--url`.
- Find the Tailscale CLI inside the Mac App Store app when it is not on `PATH`.
- Add `GET /attention/prompts` and `POST /attention/respond` so the Apple Watch app can show a permission request's choices and answer it. A reply is sent only when the prompt on screen still matches.
- Send widget pushes to the Apple Watch widgets as well as the iPhone widgets. Each platform keeps its own registration, and switching an install between the development and production APNs environments replaces the old registration.
- Stop sending notifications to devices removed with `reattachd devices revoke`, and remove APNs tokens that Apple reports as unregistered.
- Keep setup tokens created by `reattachd setup` while paired devices are active. Previously the daemon could overwrite them within seconds, so the QR code was rejected as invalid.
- Keep the desktop tmux selection when the app's stream reconnects.

### iOS, watchOS and Mac

- New Apple Watch app: see pending permission requests, read them, and reply with a tap (replying requires Reattach Pro). Watch complications and Smart Stack widgets show the pending count. A setting shows the choices above the request details.
- First launch shows the commands to run on the computer, with a copy button, and asks for notification permission after pairing.
- Direct input shows esc, ctrl, tab, arrow and symbol keys above the on-screen keyboard. ⌘⇧P opens permission requests and ⌘⇧I switches the input mode.
- Command history keeps 100 entries for everyone.
- Reattach for Mac accepts the whole setup URL, and `reattachd init` can connect it directly.
- Update reattachd to 2.1.0 for the Watch app, `reattachd init`, and widget updates on Apple Watch.

## 2.0.4 — Daemon release in preparation; iOS 2.0.1 in preparation

### Daemon

- Report whether Claude Code or Codex is working in each pane, detected from "esc to interrupt" on its screen, as `agent` in `GET /activity`.
- Use tmux's window activity flag as the unread state for windows with `monitor-activity` enabled, so unread matches the tmux status line.

### iOS and Mac

- Show a pulsing purple dot for panes where a coding agent is working; running panes are not counted as unread, and the widget shows a separate running count.
- Follow tmux's activity flag for unread panes; a pane is marked read when opened, including after moving between panes.
- Update reattachd to 2.0.4 for these indicators.

## 2.0.3 — Daemon released 2026-11-16

### Daemon

- Track unread pane output per paired device with `GET /activity` and `POST /activity/read`. Read receipts are persisted, and an older acknowledgement cannot clear newer output.
- Send silent WidgetKit push updates when permission requests or unread counts change, using tokens registered through `/widget-devices`. Visible notification banners are not affected.
- Apply each device's notification preference (all notifications, permission requests only, or off) to both APNs environments.
- Detect Codex tool-permission prompts that end with "enter to submit | esc to cancel".

### iOS

- Add Home Screen widgets showing pending permission requests and unread panes across all configured servers.
- Show permission requests from every server in one inbox; replies use the request's own server.
- Mark panes with unread output in blue, separately from orange permission requests.
- Choose all notifications, permission requests only, or none in App Settings.
- Optionally open new permission requests automatically while using the app, and close the inbox when no requests remain.
- Improve Codex tool-permission option parsing and fix pull-to-refresh reopening the last pane.
- Requires reattachd 2.0.3 or later for widgets, unread indicators, and notification preferences.

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
