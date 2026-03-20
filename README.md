# ghostty-notify

A Claude Code plugin that delivers native macOS notifications when Claude needs your attention, with smart Ghostty terminal tab focusing.

## What it does

- **Native macOS notifications** — uses `UNUserNotificationCenter` via a lightweight Swift app (not `osascript` hacks)
- **Ghostty tab focusing** — clicking a notification activates Ghostty and focuses the exact terminal tab running that Claude session
- **Smart suppression** — skips notifications when you're already looking at the right Ghostty tab
- **Debounced** — waits 3 seconds before firing; if you respond in that window, no notification
- **Rich context** — shows project name, git branch, notification type (permission prompt, task complete, etc.), and the last tool action

### Notification types

| Type | Subtitle shown |
|------|---------------|
| Permission prompt | "Permission Required" |
| Idle / waiting | "Waiting for Input" |
| Elicitation dialog | "Input Requested" |
| Auth success | "Authenticated" |
| Task stop | "Task Complete" |

## Requirements

- macOS (Apple Silicon or Intel)
- [Ghostty](https://ghostty.org) terminal
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Xcode Command Line Tools (`xcode-select --install`)
- `jq` recommended (falls back to `python3` if not installed)

## Install

### As a Claude Code plugin

```bash
claude plugins add /path/to/ghostty-notify
```

Then run the build script:

```bash
cd ~/.claude/plugins/cache/ghostty-notify/ghostty-notify/*/
bash install.sh
```

### Manual install

```bash
git clone https://github.com/YOUR_USERNAME/ghostty-notify.git ~/Developer/ghostty-notify
cd ~/Developer/ghostty-notify
bash install.sh
```

Then add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "enabledPlugins": {
    "ghostty-notify@YOUR_USERNAME": true
  }
}
```

## How it works

Three hooks wire into Claude Code's lifecycle:

1. **`SessionStart`** — captures the Ghostty terminal UUID for the session via AppleScript, saves it to `/tmp/claude-ghostty/<session_id>`
2. **`Notification`** — on any notification event, waits 3s, checks if you're already focused on that tab, enriches the message with the last tool action from the transcript, then launches the `ClaudeNotify.app` with base64-encoded hook data
3. **`UserPromptSubmit`** — dismisses any pending notifications when you send a new message

The Swift app (`ClaudeNotify.app`) runs as an `LSUIElement` (no dock icon), posts the notification, and handles click-to-focus via AppleScript.

## Files

```
.claude-plugin/
  plugin.json          # Hook definitions for Claude Code
  marketplace.json     # Plugin metadata
src/
  ClaudeNotify.swift   # Notification app source
  Info.plist           # App bundle config
scripts/
  common.sh            # Shared utilities (jq/python3 JSON helpers)
  ghostty-notify.sh    # Notification hook
  ghostty-dismiss.sh   # Dismiss hook
  ghostty-session-start.sh  # Session start hook
install.sh             # Build & setup script
build/                 # Created by install.sh
  ClaudeNotify.app/    # Compiled app bundle
```

## Troubleshooting

**No notifications appearing?**
- Check notification permissions: System Settings > Notifications > Claude Notify
- Check logs: `cat /tmp/claude-notify.log`

**Notifications fire when I'm already looking at the tab?**
- Ensure `ghostty-session-start.sh` ran: `ls /tmp/claude-ghostty/`
- Ghostty must support AppleScript (`id of focused terminal`)

**jq not found warnings?**
- Install via `brew install jq`, or the plugin will fall back to `python3`

## License

MIT
