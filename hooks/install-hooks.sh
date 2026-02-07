#!/bin/bash
# Install Reattach hooks for Claude Code and Codex

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REATTACH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_COMMAND="$REATTACH_DIR/hooks/notify.sh"
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
HOOK_FILE="$SCRIPT_DIR/idle-notification.json"
CODEX_CONFIG_DIR="$HOME/.codex"
CODEX_CONFIG_FILE="$CODEX_CONFIG_DIR/config.toml"

# Create .claude directory if it doesn't exist
mkdir -p "$CLAUDE_SETTINGS_DIR"

# Create temporary file with replaced paths
TEMP_HOOK_FILE=$(mktemp)
sed "s|{{REATTACH_DIR}}|$REATTACH_DIR|g" "$HOOK_FILE" > "$TEMP_HOOK_FILE"

# If settings.json doesn't exist, create it with the hook
if [ ! -f "$CLAUDE_SETTINGS_FILE" ]; then
    cp "$TEMP_HOOK_FILE" "$CLAUDE_SETTINGS_FILE"
    echo "Created $CLAUDE_SETTINGS_FILE with Reattach hooks"
else
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
            Stop: (($eh.Stop // []) + ($nh.Stop // []) | unique)
          }
        )
      }
    ' "$CLAUDE_SETTINGS_FILE" "$TEMP_HOOK_FILE")

    # Write merged settings back
    echo "$MERGED" > "$CLAUDE_SETTINGS_FILE"
    echo "Merged Reattach hooks into $CLAUDE_SETTINGS_FILE"
fi

# Install Codex notify command (if not already configured)
mkdir -p "$CODEX_CONFIG_DIR"

rm "$TEMP_HOOK_FILE"

if [ ! -f "$CODEX_CONFIG_FILE" ]; then
    cat > "$CODEX_CONFIG_FILE" << EOF
# Reattach push notification hook
notify = ["$HOOK_COMMAND"]
EOF
    echo "Created $CODEX_CONFIG_FILE with Reattach notify hook"
    exit 0
fi

if grep -Eq '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG_FILE"; then
    if grep -Eq "^[[:space:]]*notify[[:space:]]*=[[:space:]]*\\[\"$HOOK_COMMAND\"\\][[:space:]]*$" "$CODEX_CONFIG_FILE"; then
        {
            echo "# Reattach push notification hook"
            echo "notify = [\"$HOOK_COMMAND\"]"
            echo ""
            sed '/^# Reattach push notification hook$/d' "$CODEX_CONFIG_FILE" \
                | sed "\|^[[:space:]]*notify[[:space:]]*=[[:space:]]*\\[\"$HOOK_COMMAND\"\\][[:space:]]*$|d"
        } > "$CODEX_CONFIG_FILE.tmp"
        mv "$CODEX_CONFIG_FILE.tmp" "$CODEX_CONFIG_FILE"
        echo "Normalized Reattach notify hook placement in $CODEX_CONFIG_FILE"
    else
        echo "Skipped Codex update: notify is already configured in $CODEX_CONFIG_FILE"
        echo "Add Reattach manually if needed: notify = [\"$HOOK_COMMAND\"]"
    fi
else
    {
        echo "# Reattach push notification hook"
        echo "notify = [\"$HOOK_COMMAND\"]"
        echo ""
        cat "$CODEX_CONFIG_FILE"
    } > "$CODEX_CONFIG_FILE.tmp"
    mv "$CODEX_CONFIG_FILE.tmp" "$CODEX_CONFIG_FILE"
    echo "Added Reattach notify hook to $CODEX_CONFIG_FILE"
fi
