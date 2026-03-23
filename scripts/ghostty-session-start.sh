#!/bin/bash
# Capture Ghostty terminal UUID at session start and save it keyed by session_id
set -euo pipefail

[ "${TERM_PROGRAM:-}" = "ghostty" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Auto-build ClaudeNotify.app on first session if needed
if [ ! -x "$PLUGIN_ROOT/build/ClaudeNotify.app/Contents/MacOS/ClaudeNotify" ]; then
    bash "$PLUGIN_ROOT/install.sh" --auto 2>/dev/null || true
fi

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

ensure_db
sqlite3 "$NOTIFY_DB" "INSERT OR REPLACE INTO sessions (session_id, terminal_uuid, updated_at) VALUES ('$SESSION_ID', '$TID', strftime('%s','now'));"
exit 0
