#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Read hook JSON from stdin
RAW=$(cat)

TRANSCRIPT=$(echo "$RAW" | json_val "transcript_path")

# Count user messages before delay (to detect if user responded, not just Claude writing)
USER_MSGS_BEFORE=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    USER_MSGS_BEFORE=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || true)
fi

# Delay — gives user time to respond before notification fires
sleep 3

# Check if Ghostty is focused AND the active tab is THIS session's terminal
SESSION_ID=$(echo "$RAW" | json_val "session_id")
FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
if [ "${FRONTMOST,,}" = "ghostty" ]; then
    # Check by terminal UUID (exact match)
    SAVED_TID=""
    if [ -n "$SESSION_ID" ] && [ -f "/tmp/claude-ghostty/$SESSION_ID" ]; then
        SAVED_TID=$(cat "/tmp/claude-ghostty/$SESSION_ID" 2>/dev/null || true)
    fi
    if [ -n "$SAVED_TID" ]; then
        ACTIVE_TID=$(osascript -e '
            tell application "Ghostty"
                try
                    return id of focused terminal of selected tab of first window
                end try
                return ""
            end tell' 2>/dev/null || true)
        if [ "$ACTIVE_TID" = "$SAVED_TID" ]; then
            exit 0
        fi
    fi
fi

# Check if user submitted a new message during the delay
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    USER_MSGS_AFTER=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || true)
    if [ "$USER_MSGS_AFTER" -gt "$USER_MSGS_BEFORE" ]; then
        exit 0
    fi
fi

# Enrich message with actual tool/command from transcript
ENRICHED_MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    ENRICHED_MSG=$(extract_last_tool "$TRANSCRIPT")
fi

if [ -n "$ENRICHED_MSG" ]; then
    RAW=$(echo "$RAW" | json_set "message" "$ENRICHED_MSG")
fi

# Base64 encode and launch
INPUT=$(echo "$RAW" | base64)

pkill -f "ClaudeNotify.app" 2>/dev/null || true
open -n -a "$NOTIFY_APP" --args "$INPUT" &
exit 0
