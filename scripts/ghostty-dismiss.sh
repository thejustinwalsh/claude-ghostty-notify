#!/bin/bash
# Dismiss pending Claude notifications for this session only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

RAW=$(cat)
SESSION_ID=$(echo "$RAW" | json_val "session_id")

if [ -n "$SESSION_ID" ]; then
    # Keep the session's terminal mapping alive: UserPromptSubmit fires on every
    # user message, so sessions in active use never hit the 24h purge even when
    # they live for days (e.g. inside a long-running Zellij/tmux session).
    ensure_db
    sqlite3 "$NOTIFY_DB" "UPDATE sessions SET updated_at = strftime('%s','now') WHERE session_id = '$SESSION_ID';" 2>/dev/null
    open -n -a "$NOTIFY_APP" --args "dismiss:$SESSION_ID" &
fi
exit 0
