#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/ClaudeNotify.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building ClaudeNotify.app..."

# Check for Swift compiler
if ! command -v swiftc &>/dev/null; then
    echo "Error: swiftc not found. Install Xcode or Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# Clean previous build
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Compile Swift source
swiftc "$SCRIPT_DIR/src/ClaudeNotify.swift" \
    -o "$MACOS/ClaudeNotify" \
    -framework Foundation \
    -framework UserNotifications \
    -framework AppKit \
    -O

echo "==> Compiled ClaudeNotify binary"

# Copy Info.plist
cp "$SCRIPT_DIR/src/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc codesign
codesign --force --sign - "$APP_DIR"
echo "==> Ad-hoc codesigned"

# Copy Claude icon if available
CLAUDE_ICON=""
for icon_path in \
    "/Applications/Claude.app/Contents/Resources/AppIcon.icns" \
    "/Applications/Claude.app/Contents/Resources/icon.icns" \
    "$HOME/Applications/Claude.app/Contents/Resources/AppIcon.icns"; do
    if [ -f "$icon_path" ]; then
        CLAUDE_ICON="$icon_path"
        break
    fi
done

if [ -n "$CLAUDE_ICON" ]; then
    cp "$CLAUDE_ICON" "$RESOURCES/AppIcon.icns"
    echo "==> Copied Claude icon from $CLAUDE_ICON"
else
    echo "    (Claude.app icon not found — notifications will use default icon)"
fi

# Copy notification sound
TINK_SRC="/System/Library/Sounds/Tink.aiff"
if [ -f "$TINK_SRC" ]; then
    cp "$TINK_SRC" "$RESOURCES/Tink.aiff"
    echo "==> Copied Tink.aiff notification sound"
else
    echo "    (Tink.aiff not found — notifications will use default sound)"
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/scripts/"*.sh

echo ""
echo "==> Opening ClaudeNotify.app to request notification permissions..."
echo "    Please click 'Allow' when prompted."
open -a "$APP_DIR"

echo ""
echo "Done! The ghostty-notify plugin is ready."
echo "Enable it in Claude Code with: claude plugins enable ghostty-notify"
