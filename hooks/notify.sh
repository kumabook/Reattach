#!/bin/bash
# Claude Code Stop hook - sends notification with pane info and last message

# Read JSON from stdin
INPUT=$(cat)

# Extract fields from JSON
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

# Default values
TITLE="Claude Code"
BODY="Waiting for input"

# Try to get the last Claude message from transcript
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Get the last assistant message from the JSONL transcript
    # Extract text content from the message
    LAST_MESSAGE=$(tac "$TRANSCRIPT_PATH" 2>/dev/null | \
        while IFS= read -r line; do
            ROLE=$(echo "$line" | jq -r '.type // empty')
            if [ "$ROLE" = "assistant" ]; then
                # Extract text from message content
                echo "$line" | jq -r '
                    [.message.content[]? | select(.type == "text") | .text // empty] | join("\n")
                ' 2>/dev/null
                break
            fi
        done)

    if [ -n "$LAST_MESSAGE" ]; then
        BODY="$LAST_MESSAGE"
    fi
fi

PANE_TARGET=""

if [ -n "$CWD" ]; then
    DIR_NAME=$(basename "$CWD")

    # Use TMUX_PANE if available for exact pane identification
    if [ -n "$TMUX_PANE" ]; then
        PANE_TARGET=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
        if [ -n "$PANE_TARGET" ]; then
            SESSION_WINDOW=$(echo "$PANE_TARGET" | cut -d. -f1)
            TITLE="$SESSION_WINDOW · $DIR_NAME"
        else
            TITLE="$DIR_NAME"
        fi
    else
        # Fallback: find tmux pane with matching cwd
        PANE_INFO=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}:#{pane_current_path}' 2>/dev/null | grep ":${CWD}$" | head -1)

        if [ -n "$PANE_INFO" ]; then
            PANE_TARGET=$(echo "$PANE_INFO" | cut -d: -f1-2)
            SESSION_WINDOW=$(echo "$PANE_TARGET" | cut -d. -f1)
            TITLE="$SESSION_WINDOW · $DIR_NAME"
        else
            TITLE="$DIR_NAME"
        fi
    fi
fi

# Escape special characters for JSON
BODY_ESCAPED=$(printf '%s' "$BODY" | jq -Rs '.')

# Build JSON payload
if [ -n "$PANE_TARGET" ]; then
    PAYLOAD="{\"title\":\"$TITLE\",\"body\":$BODY_ESCAPED,\"pane_target\":\"$PANE_TARGET\"}"
else
    PAYLOAD="{\"title\":\"$TITLE\",\"body\":$BODY_ESCAPED}"
fi

# Send notification
curl -s -X POST http://localhost:8787/notify \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD"
