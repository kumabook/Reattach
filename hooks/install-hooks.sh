#!/bin/bash
# Install Reattach Claude Code hooks

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REATTACH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
HOOK_FILE="$SCRIPT_DIR/idle-notification.json"

# Create .claude directory if it doesn't exist
mkdir -p "$CLAUDE_SETTINGS_DIR"

# Create temporary file with replaced paths
TEMP_HOOK_FILE=$(mktemp)
sed "s|{{REATTACH_DIR}}|$REATTACH_DIR|g" "$HOOK_FILE" > "$TEMP_HOOK_FILE"

# If settings.json doesn't exist, create it with the hook
if [ ! -f "$CLAUDE_SETTINGS_FILE" ]; then
    cp "$TEMP_HOOK_FILE" "$CLAUDE_SETTINGS_FILE"
    rm "$TEMP_HOOK_FILE"
    echo "Created $CLAUDE_SETTINGS_FILE with Reattach hooks"
    exit 0
fi

# Merge hooks into existing settings
# Use jq to deep merge the hooks
MERGED=$(jq -s '
  def deep_merge:
    if type == "array" then
      .[0] as $base | .[1] as $new |
      if ($base | type) == "object" and ($new | type) == "object" then
        $base * $new
      elif ($base | type) == "array" and ($new | type) == "array" then
        $base + $new
      else
        $new
      end
    else
      .
    end;

  .[0] as $existing | .[1] as $new |
  $existing * {
    hooks: (
      ($existing.hooks // {}) as $eh |
      ($new.hooks // {}) as $nh |
      $eh * {
        Notification: (($eh.Notification // []) + ($nh.Notification // []) | unique)
      }
    )
  }
' "$CLAUDE_SETTINGS_FILE" "$TEMP_HOOK_FILE")

# Write merged settings back
echo "$MERGED" > "$CLAUDE_SETTINGS_FILE"
rm "$TEMP_HOOK_FILE"
echo "Merged Reattach hooks into $CLAUDE_SETTINGS_FILE"
