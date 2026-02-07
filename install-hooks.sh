#!/bin/bash
# Install Reattach hooks for Claude Code and Codex

set -e

CLAUDE_HOOK_COMMAND="reattachd notify"
CODEX_NOTIFY_LINE='notify = ["reattachd", "notify"]'
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG_FILE="$CODEX_CONFIG_DIR/config.toml"

# Create .claude directory if it doesn't exist
mkdir -p "$CLAUDE_SETTINGS_DIR"

# Create temporary hook JSON
TEMP_HOOK_FILE=$(mktemp)
cat > "$TEMP_HOOK_FILE" << EOF
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_HOOK_COMMAND",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF

# If settings.json doesn't exist, create it with the hook
if [ ! -f "$CLAUDE_SETTINGS_FILE" ]; then
    cp "$TEMP_HOOK_FILE" "$CLAUDE_SETTINGS_FILE"
    echo "Created $CLAUDE_SETTINGS_FILE with Reattach hooks"
else
    # Merge hooks into existing settings
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
            Stop: (($eh.Stop // []) + ($nh.Stop // []) | unique)
          }
        )
      }
    ' "$CLAUDE_SETTINGS_FILE" "$TEMP_HOOK_FILE")

    echo "$MERGED" > "$CLAUDE_SETTINGS_FILE"
    echo "Merged Reattach hooks into $CLAUDE_SETTINGS_FILE"
fi

# Install Codex notify command (if not already configured)
mkdir -p "$CODEX_CONFIG_DIR"
rm "$TEMP_HOOK_FILE"

if [ ! -f "$CODEX_CONFIG_FILE" ]; then
    cat > "$CODEX_CONFIG_FILE" << EOF
# Reattach push notification hook
$CODEX_NOTIFY_LINE
EOF
    echo "Created $CODEX_CONFIG_FILE with Reattach notify hook"
    exit 0
fi

if grep -Eq '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG_FILE"; then
    if grep -Eq '^[[:space:]]*notify[[:space:]]*=[[:space:]]*\["reattachd",[[:space:]]*"notify"\][[:space:]]*$' "$CODEX_CONFIG_FILE"; then
        {
            echo "# Reattach push notification hook"
            echo "$CODEX_NOTIFY_LINE"
            echo ""
            sed '/^# Reattach push notification hook$/d' "$CODEX_CONFIG_FILE" \
                | sed '/^[[:space:]]*notify[[:space:]]*=[[:space:]]*\["reattachd",[[:space:]]*"notify"\][[:space:]]*$/d'
        } > "$CODEX_CONFIG_FILE.tmp"
        mv "$CODEX_CONFIG_FILE.tmp" "$CODEX_CONFIG_FILE"
        echo "Normalized Reattach notify hook placement in $CODEX_CONFIG_FILE"
    else
        echo "Skipped Codex update: notify is already configured in $CODEX_CONFIG_FILE"
        echo "Add Reattach manually if needed: $CODEX_NOTIFY_LINE"
    fi
else
    {
        echo "# Reattach push notification hook"
        echo "$CODEX_NOTIFY_LINE"
        echo ""
        cat "$CODEX_CONFIG_FILE"
    } > "$CODEX_CONFIG_FILE.tmp"
    mv "$CODEX_CONFIG_FILE.tmp" "$CODEX_CONFIG_FILE"
    echo "Added Reattach notify hook to $CODEX_CONFIG_FILE"
fi
