# Permission status hooks

The permission-status hooks report `PermissionRequest` and resolution events to
reattachd. They never output an approval decision or send terminal keys.
The app polls the authenticated `/attention` endpoint and shows all waiting panes
on the active server, with a menu to open each pane.

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
mobile device credentials cannot submit permission events. No tool arguments
or commands are sent to the app. Identical requests are correlated by a hash
of their tool name and arguments; Stop/Interrupt/SessionEnd clear remaining
requests for the corresponding session/turn.

Status is in memory and starts empty after a daemon restart. A missing lifecycle
event can leave a waiting indication until a later session/turn-end event.
Approval and denial remain in the terminal in this version.

References:
- https://learn.chatgpt.com/docs/hooks
- https://code.claude.com/docs/en/hooks
