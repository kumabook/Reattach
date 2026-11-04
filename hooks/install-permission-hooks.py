#!/usr/bin/env python3
"""Merge permission-status hooks without changing agent approval decisions or trust."""
import argparse
import json
import shlex
from pathlib import Path

EVENTS = {
    '.codex/hooks.json': ['PermissionRequest', 'PostToolUse', 'Stop', 'Interrupt', 'SessionEnd', 'UserPromptSubmit'],
    '.claude/settings.json': ['PermissionRequest', 'Notification', 'PostToolUse', 'PostToolUseFailure', 'Stop', 'SessionEnd', 'UserPromptSubmit'],
}


def merge(document, events, command):
    hooks = document.setdefault('hooks', {})
    for event in events:
        entries = hooks.setdefault(event, [])
        # Keep all other tools' hooks and our existing completion notifications.
        for entry in entries:
            entry['hooks'] = [h for h in entry.get('hooks', [])
                              if h.get('statusMessage') != 'Reattach permission status'
                              and not (event == 'Notification'
                                       and entry.get('matcher') == 'permission_prompt'
                                       and h.get('command') == 'reattachd notify')]
        entries[:] = [entry for entry in entries if entry.get('hooks')]
        entries.append({
            'matcher': 'permission_prompt' if event == 'Notification' else '',
            'hooks': [{'type': 'command', 'command': command, 'timeout': 3,
                       'statusMessage': 'Reattach permission status'}],
        })
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error('binary does not exist')
    command = shlex.quote(str(binary)) + ' agent-event'
    updates = []
    for relative, events in EVENTS.items():
        path = args.home / relative
        document = json.loads(path.read_text()) if path.exists() else {}
        content = json.dumps(merge(document, events, command), ensure_ascii=False, indent=2) + '\n'
        updates.append((path, content))
        print(f'{path}: {", ".join(events)}')
    print(f'Command: {command}')
    if args.apply:
        for path, content in updates:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + '.reattach-tmp')
            temporary.write_text(content)
            temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
            temporary.replace(path)
        print('Installed. Review the new Codex hooks in /hooks or Settings > Hooks; trust is not changed by this installer.')
    else:
        print('Preview only. Pass --apply to write these changes.')


if __name__ == '__main__':
    main()
