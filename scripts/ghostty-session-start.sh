#!/bin/bash
# Capture Ghostty terminal UUID at session start and save it keyed by session_id
set -euo pipefail

[ "${TERM_PROGRAM:-}" = "ghostty" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

RAW=$(cat)
SESSION_ID=$(echo "$RAW" | json_val "session_id")
[ -n "$SESSION_ID" ] || exit 0

TID=$(osascript -e '
tell application "Ghostty"
    try
        return id of focused terminal of selected tab of first window
    end try
    return ""
end tell' 2>/dev/null || true)

[ -n "$TID" ] || exit 0

mkdir -p /tmp/claude-ghostty
echo "$TID" > "/tmp/claude-ghostty/$SESSION_ID"
exit 0
