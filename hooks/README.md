# Permission status hooks

The permission-status hooks report `PermissionRequest` and resolution events to
reattachd. They never output an approval decision or send terminal keys.
The app polls the authenticated `/attention` endpoint and shows all waiting panes
on the active server. Tap the checkmark and its count badge to review waiting terminals as swipeable
cards, choose a numbered reply, send Enter/Esc or a typed reply, or open a pane.
Long cards scroll vertically; hold the terminal preview to expand it, or pull
down from the top to refresh.
The inbox rechecks status and terminal output before sending; changed content
must be reviewed again. Replies use terminal input, so Enter and Esc retain the
meaning shown by the agent. This check is not an atomic agent approval protocol.

Build the daemon and start it before installing the hooks:

```sh
cargo build --release --manifest-path reattachd/Cargo.toml
python3 hooks/install-permission-hooks.py --binary reattachd/target/release/reattachd
python3 hooks/install-permission-hooks.py --binary reattachd/target/release/reattachd --apply
```

The first command previews the merged settings. Existing hooks are preserved.
The installer targets `~/.codex/hooks.json` and `~/.claude/settings.json`.
Codex requires reviewing and trusting the new definitions in `/hooks` or
Settings > Hooks. The installer does not grant trust. Restart an agent if its
current session does not reload hook settings.

Only agents running inside tmux can be associated with a pane. Hooks need the
same `REATTACHD_DATA_DIR` and tmux environment as the daemon (default port 8787).
A private token file in the daemon data directory authenticates local events;
mobile device credentials cannot submit permission events. Permission events contain no tool arguments
or commands; the inbox separately reads the terminal output for review. Identical requests are correlated by a hash
of their tool name and arguments; Stop/Interrupt/SessionEnd clear remaining
requests for the corresponding session/turn.

Status is in memory and starts empty after a daemon restart. A missing lifecycle
event can leave a waiting indication until a later session/turn-end event.
The hooks still only report status; replies are sent by explicit user actions in the app.

As a fallback, `/attention` also detects the current English Codex command-approval
screen (the “Would you like to run the following command?” dialog). It only reads
visible panes whose foreground process is `codex`; private panes, copy mode,
scrollback, and exited panes are excluded. These entries disappear when the dialog
leaves the screen. They do not generate push notifications. Other dialog formats
still require lifecycle hooks. Hook trust and approval decisions are unchanged.

References:
- https://learn.chatgpt.com/docs/hooks
- https://code.claude.com/docs/en/hooks
