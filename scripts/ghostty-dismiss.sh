#!/bin/bash
# Dismiss any pending Claude notifications

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

pkill -f "ClaudeNotify.app" 2>/dev/null || true
open -n -a "$NOTIFY_APP" --args dismiss &
exit 0
