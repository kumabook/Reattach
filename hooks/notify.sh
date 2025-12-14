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

if [ -n "$CWD" ]; then
    DIR_NAME=$(basename "$CWD")

    # Try to find tmux pane with matching cwd
    PANE_INFO=$(tmux list-panes -a -F '#{session_name}:#{window_index}:#{window_name}:#{pane_current_path}' 2>/dev/null | grep ":${CWD}$" | head -1)

    if [ -n "$PANE_INFO" ]; then
        SESSION_NAME=$(echo "$PANE_INFO" | cut -d: -f1)
        WINDOW_INDEX=$(echo "$PANE_INFO" | cut -d: -f2)
        TITLE="$SESSION_NAME:$WINDOW_INDEX · $DIR_NAME"
    else
        TITLE="$DIR_NAME"
    fi
fi

# Escape special characters for JSON
BODY_ESCAPED=$(printf '%s' "$BODY" | jq -Rs '.')

# Send notification with cwd info
curl -s -X POST http://localhost:8787/notify \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"$TITLE\",\"body\":$BODY_ESCAPED,\"cwd\":\"$CWD\"}"
