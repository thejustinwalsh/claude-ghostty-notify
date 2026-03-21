#!/bin/bash
# Dismiss pending Claude notifications for this session only

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

RAW=$(cat)
SESSION_ID=$(echo "$RAW" | json_val "session_id")

if [ -n "$SESSION_ID" ]; then
    open -n -a "$NOTIFY_APP" --args "dismiss:$SESSION_ID" &
fi
exit 0
