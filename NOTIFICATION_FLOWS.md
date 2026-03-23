# Notification Flows

This document codifies exactly when and how notifications fire, dismiss, and focus.

## Hooks Registered

| Hook Event | Script | Async | Timeout |
|---|---|---|---|
| `Notification` | `ghostty-notify.sh` | yes | 30s |
| `SessionStart` | `ghostty-session-start.sh` | no | 5s |
| `UserPromptSubmit` | `ghostty-dismiss.sh` | yes | 5s |

## Notification Types (from Claude Code)

| `notification_type` | Action | Reason |
|---|---|---|
| `permission_prompt` | **NOTIFY** | Claude needs permission — user must act |
| `elicitation_dialog` | **NOTIFY** | Claude is showing an input dialog — user must act |
| `idle_prompt` | **SKIP** | Fires on task complete AND genuine idle — too many false positives |
| `auth_success` | **SKIP** | Informational only, no action needed |
| (empty/other) | **SKIP** | Unknown or non-actionable |

## Flow 1: Session Start

Captures the Ghostty terminal UUID so notifications can focus the correct tab when clicked.

```mermaid
sequenceDiagram
    participant CC as Claude Code
    participant SS as ghostty-session-start.sh
    participant G as Ghostty (AppleScript)
    participant DB as SQLite store.db

    CC->>SS: SessionStart hook (stdin: JSON with session_id)
    SS->>SS: Check TERM_PROGRAM == "ghostty"
    alt Not Ghostty
        SS->>SS: exit 0
    end
    SS->>SS: Auto-build ClaudeNotify.app if needed
    SS->>G: AppleScript: get id of focused terminal
    G-->>SS: terminal UUID
    SS->>DB: INSERT OR REPLACE session terminal UUID
```

## Flow 2: Notification (Permission Prompt / Elicitation Dialog)

```mermaid
sequenceDiagram
    participant CC as Claude Code
    participant NS as ghostty-notify.sh
    participant G as Ghostty (AppleScript)
    participant CN as ClaudeNotify.app
    participant NC as macOS Notification Center
    participant DB as SQLite store.db

    CC->>NS: Notification hook (stdin: JSON)
    NS->>NS: Read notification_type

    alt notification_type NOT in [permission_prompt, elicitation_dialog]
        NS->>NS: exit 0 (skip)
    end

    NS->>NS: Record transcript user message count
    NS->>NS: sleep 3 (grace period)

    NS->>G: AppleScript: is Ghostty frontmost?
    alt Ghostty is frontmost AND correct tab is focused
        NS->>NS: exit 0 (user is already looking at it)
    end

    NS->>NS: Check if user responded during sleep
    alt User message count increased
        NS->>NS: exit 0 (user already responded)
    end

    NS->>NS: Extract last tool from transcript (enrich body)
    NS->>NS: Base64-encode JSON payload
    NS->>CN: open -n -a ClaudeNotify.app --args {base64}
    CN->>NC: Request authorization (if first time)
    CN->>NC: Post UNNotificationRequest (id: claude-{session}-{timestamp})
    CN->>DB: INSERT notification ID for session
    CN->>CN: Auto-exit after 30s if no click
```

## Flow 3: Notification Click (Focus Ghostty Tab)

```mermaid
sequenceDiagram
    participant U as User
    participant NC as macOS Notification Center
    participant CN as ClaudeNotify.app
    participant DB as SQLite store.db
    participant G as Ghostty (AppleScript)

    U->>NC: Click notification banner
    NC->>CN: didReceive response callback
    CN->>DB: SELECT terminal_uuid WHERE session_id
    alt Terminal UUID found
        CN->>G: AppleScript: activate + focus terminal by UUID
    else No UUID
        CN->>G: AppleScript: just activate Ghostty
    end
    CN->>CN: Terminate after 0.5s
```

## Flow 4: Dismiss on User Prompt Submit

```mermaid
sequenceDiagram
    participant CC as Claude Code
    participant DS as ghostty-dismiss.sh
    participant CN as ClaudeNotify.app
    participant DB as SQLite store.db
    participant NC as macOS Notification Center

    CC->>DS: UserPromptSubmit hook (stdin: JSON with session_id)
    DS->>CN: open -n -a ClaudeNotify.app --args "dismiss:{session_id}"
    CN->>DB: SELECT + DELETE notification IDs for session
    CN->>NC: removeDeliveredNotifications(withIdentifiers: ids)

    CN->>CN: Terminate after 0.3s
```

## Suppression Logic (ghostty-notify.sh)

Notifications are suppressed when ANY of these conditions are true:

1. **Wrong type**: `notification_type` is not `permission_prompt` or `elicitation_dialog`
2. **User is looking**: Ghostty is frontmost AND the active tab matches this session's terminal UUID
3. **User already responded**: User message count in transcript increased during the 3s delay

## Storage: SQLite Database

All persistent state is in `~/Library/Application Support/com.claude.notify/store.db`.

Both the Swift app and shell scripts (via `sqlite3` CLI) share this database.
Entries older than 24 hours are auto-purged on every access.

### Schema

```sql
-- Terminal UUID per session (for click-to-focus)
CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    terminal_uuid TEXT,
    updated_at REAL DEFAULT (strftime('%s','now'))
);

-- Posted notification IDs per session (for dismiss)
CREATE TABLE notifications (
    notif_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    created_at REAL DEFAULT (strftime('%s','now'))
);
```

### Access Pattern

| Operation | Writer | Reader |
|---|---|---|
| Store terminal UUID | `ghostty-session-start.sh` (sqlite3 CLI) | `ghostty-notify.sh` (sqlite3 CLI), `ClaudeNotify.swift` (click handler) |
| Store notification ID | `ClaudeNotify.swift` (after posting) | `ClaudeNotify.swift` (dismiss mode) |
| Purge old entries | Both (on every access) | — |

## Running Tests

```bash
# Build then run inline tests (uses in-memory SQLite, no side effects)
bash install.sh
./build/ClaudeNotify.app/Contents/MacOS/ClaudeNotify --test
```
