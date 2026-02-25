#!/bin/bash
set -euo pipefail

LABEL="com.local.xcode-mcp-allower"
APP_NAME="Xcode MCP Auto-Allower"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/xcode-mcp-allower.log"
CONFIG_DIR="$HOME/.config/xcode-mcp-allower"

echo "==> Uninstalling ${APP_NAME}..."

# Stop daemon
echo "    Stopping daemon..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

# Remove LaunchAgent plist
if [ -f "$PLIST" ]; then
    rm -f "$PLIST"
    echo "    Removed LaunchAgent plist."
fi

# Remove app bundle
if [ -d "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
    echo "    Removed app bundle."
fi

# Remove old raw binary (migration leftover)
if [ -f "$HOME/.local/bin/xcode-mcp-allower" ]; then
    rm -f "$HOME/.local/bin/xcode-mcp-allower"
    echo "    Removed old binary at ~/.local/bin/xcode-mcp-allower"
fi
if [ -f "$HOME/.local/bin/xcode-mcp-allower.swift" ]; then
    rm -f "$HOME/.local/bin/xcode-mcp-allower.swift"
    echo "    Removed old source at ~/.local/bin/xcode-mcp-allower.swift"
fi

# Reset Accessibility permission
echo "    Resetting Accessibility permission..."
tccutil reset Accessibility "$LABEL" 2>/dev/null || true

# Remove config
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    echo "    Removed config."
fi

# Remove log file
if [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE"
    echo "    Removed log file."
fi

echo ""
echo "==> Uninstall complete. ${APP_NAME} has been fully removed."
