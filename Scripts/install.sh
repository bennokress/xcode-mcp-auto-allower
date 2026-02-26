#!/bin/bash
# =============================================================================
# install.sh — Development-only install script.
# Compiles from source and installs locally without code signing.
# For user-facing distribution, see ./Scripts/build-dmg.sh instead.
# =============================================================================
set -euo pipefail

LABEL="com.bennokress.xcode-mcp-allower"
APP_NAME="Xcode MCP Auto-Allower"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_FILE="$HOME/Library/Logs/xcode-mcp-allower.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build"
BINARY_NAME="xcode-mcp-allower"

# Determine version from git tags, fallback to 1.0.0
VERSION=$(git -C "$REPO_DIR" describe --tags 2>/dev/null | sed 's/^v//' || echo "1.0.0")

echo "==> Building ${APP_NAME} v${VERSION}..."
mkdir -p "$BUILD_DIR"

# Compile app icon from Icon Composer package via actool
ICON_SRC="${REPO_DIR}/Assets/App Icon.icon"
SYMBOLS_SRC="${REPO_DIR}/Assets/Symbols.xcassets"
ICON_COMPILED=false
if [ -d "$ICON_SRC" ]; then
    echo "    Compiling app icon..."
    ACTOOL_ARGS=("$ICON_SRC")
    [ -d "$SYMBOLS_SRC" ] && ACTOOL_ARGS+=("$SYMBOLS_SRC")
    xcrun actool "${ACTOOL_ARGS[@]}" \
        --compile "$BUILD_DIR" \
        --output-partial-info-plist "${BUILD_DIR}/Icon-Info.plist" \
        --output-format human-readable-text \
        --app-icon "App Icon" \
        --include-all-app-icons \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        > /dev/null 2>&1 && ICON_COMPILED=true
    if $ICON_COMPILED; then
        echo "    App icon compiled."
    else
        echo "    Warning: actool failed, using default icon."
    fi
else
    echo "    No icon source found, using default icon."
fi

# Generate Version.swift with build-time constants
cat > "${BUILD_DIR}/Version.swift" <<VEOF
let appVersion = "${VERSION}"
let githubRepo = "bennokress/xcode-mcp-auto-allower"
let githubURL = "https://github.com/bennokress/xcode-mcp-auto-allower"
VEOF

# Compile main binary
swiftc -O "${REPO_DIR}/Sources/xcode-mcp-allower.swift" "${BUILD_DIR}/Version.swift" \
    -o "${BUILD_DIR}/${BINARY_NAME}"
echo "    Compiled successfully."

# Create .app bundle
echo "==> Creating app bundle at ${APP_DIR}..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${BINARY_NAME}" "${APP_DIR}/Contents/MacOS/${BINARY_NAME}"

# Copy compiled icon assets
ICON_ENTRIES=""
if $ICON_COMPILED; then
    cp "${BUILD_DIR}/App Icon.icns" "${APP_DIR}/Contents/Resources/"
    cp "${BUILD_DIR}/Assets.car" "${APP_DIR}/Contents/Resources/"
    ICON_ENTRIES="<key>CFBundleIconFile</key>
    <string>App Icon</string>
    <key>CFBundleIconName</key>
    <string>App Icon</string>"
fi

# Generate Info.plist (LSUIElement = no dock icon, but can show windows)
cat > "${APP_DIR}/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${LABEL}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${BINARY_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    ${ICON_ENTRIES}
</dict>
</plist>
PLISTEOF

# Ad-hoc codesign the bundle
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true
echo "    App bundle created."

# Stop existing daemon (if running)
echo "==> Stopping existing daemon (if any)..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

# Migrate: remove old raw binary
if [ -f "$HOME/.local/bin/xcode-mcp-allower" ]; then
    echo "==> Migrating: removing old binary at ~/.local/bin/xcode-mcp-allower"
    rm -f "$HOME/.local/bin/xcode-mcp-allower"
fi
if [ -f "$HOME/.local/bin/xcode-mcp-allower.swift" ]; then
    echo "==> Migrating: removing old source at ~/.local/bin/xcode-mcp-allower.swift"
    rm -f "$HOME/.local/bin/xcode-mcp-allower.swift"
fi

# Write LaunchAgent plist (--background = no window on login)
BINARY_PATH="${APP_DIR}/Contents/MacOS/${BINARY_NAME}"
echo "==> Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<LAEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_PATH}</string>
        <string>--background</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <string>${LABEL}</string>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
</dict>
</plist>
LAEOF
echo "    LaunchAgent written."

# Store repo path for in-app reinstall/update
mkdir -p "$HOME/.config/xcode-mcp-allower"
echo "$REPO_DIR" > "$HOME/.config/xcode-mcp-allower/repo-path"

# Load daemon
echo "==> Loading daemon..."
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "    Daemon loaded."

# Clean up build directory
rm -rf "$BUILD_DIR"

echo ""
echo "==> Installation complete!"
echo "    App:         ${APP_DIR}"
echo "    LaunchAgent: ${PLIST}"
echo "    Log:         ${LOG_FILE}"
echo ""
echo "    Grant Accessibility permission to '${APP_NAME}' in"
echo "    System Settings > Privacy & Security > Accessibility."
echo ""
echo "    Open the app from ~/Applications to manage, update, or uninstall."
