#!/bin/bash
# Common utilities for ghostty-notify plugin

# Determine plugin root from script location
PLUGIN_ROOT="${PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Locate ClaudeNotify.app
NOTIFY_APP="$PLUGIN_ROOT/build/ClaudeNotify.app"

# Find jq in PATH
if command -v jq &>/dev/null; then
    _JQ="$(command -v jq)"
else
    _JQ=""
fi

# json_val: extract a top-level string field with empty string default
# Usage: echo "$json" | json_val "field_name"
json_val() {
    local field="$1"
    if [ -n "$_JQ" ]; then
        "$_JQ" -r ".$field // \"\""
    else
        python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get(sys.argv[1], '')
print('' if v is None else str(v))
" "$field"
    fi
}

# json_set: set a top-level string field
# Usage: echo "$json" | json_set "field" "value"
json_set() {
    local field="$1" value="$2"
    if [ -n "$_JQ" ]; then
        "$_JQ" --arg v "$value" ".$field = \$v"
    else
        python3 -c "
import sys, json
d = json.load(sys.stdin)
d[sys.argv[1]] = sys.argv[2]
json.dump(d, sys.stdout)
" "$field" "$value"
    fi
}

# extract_last_tool: get last tool info from transcript for notification enrichment
# Usage: extract_last_tool "/path/to/transcript"
extract_last_tool() {
    local transcript="$1"
    if [ -n "$_JQ" ]; then
        tail -20 "$transcript" | "$_JQ" -rs '
            [.[] | select(.type == "assistant") | .content[]? | select(.type == "tool_use")] | last // empty |
            if .name == "Bash" then
                "Bash: " + (.input.command // "" | split("\n") | first | .[0:200])
            elif .name == "Edit" then
                "Edit: " + (.input.file_path // "")
            elif .name == "Write" then
                "Write: " + (.input.file_path // "")
            elif .name == "Read" then
                "Read: " + (.input.file_path // "")
            elif .name then
                .name + ": " + ((.input | keys | join(", ")) // "")
            else
                empty
            end
        ' 2>/dev/null || true
    else
        tail -20 "$transcript" | python3 -c "
import sys, json

lines = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            lines.append(json.loads(line))
        except:
            pass

tools = []
for entry in lines:
    if entry.get('type') == 'assistant':
        for c in (entry.get('content') or []):
            if isinstance(c, dict) and c.get('type') == 'tool_use':
                tools.append(c)

if not tools:
    sys.exit(0)

t = tools[-1]
name = t.get('name', '')
inp = t.get('input', {})

if name == 'Bash':
    cmd = (inp.get('command') or '').split(chr(10))[0][:200]
    print(f'Bash: {cmd}')
elif name in ('Edit', 'Write', 'Read'):
    print(f'{name}: {inp.get(\"file_path\", \"\")}')
elif name:
    keys = ', '.join(inp.keys()) if inp else ''
    print(f'{name}: {keys}')
" 2>/dev/null || true
    fi
}
