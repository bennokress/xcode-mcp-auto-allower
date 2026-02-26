#!/bin/bash
set -euo pipefail

# =============================================================================
# build-dmg.sh — Build, sign, notarize, and package the app into a DMG.
# Developer-only script. Not shipped to users.
#
# Signing identity:
#   DEVELOPER_ID env var, or auto-detected from Keychain.
#
# Notarization (two modes):
#   1. Keychain profile (local): store credentials once with
#        xcrun notarytool store-credentials "notarytool" --team-id TEAMID
#      The script auto-detects the "notarytool" profile.
#   2. Env vars (CI): set APPLE_ID, TEAM_ID, and APP_PASSWORD.
#
# If neither is available, notarization is skipped.
# =============================================================================

APP_NAME="Xcode MCP Auto-Allower"
LABEL="com.bennokress.xcode-mcp-allower"
BINARY_NAME="xcode-mcp-allower"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build"
DIST_DIR="${REPO_DIR}/Distribution"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

# Determine version from git tags, fallback to 1.0.0
VERSION=$(git -C "$REPO_DIR" describe --tags 2>/dev/null | sed 's/^v//' || echo "1.0.0")

echo "==> Building ${APP_NAME} v${VERSION}..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------------------
# Step 1: Compile app icon
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 2: Generate Version.swift
# ---------------------------------------------------------------------------
cat > "${BUILD_DIR}/Version.swift" <<VEOF
let appVersion = "${VERSION}"
let githubRepo = "bennokress/xcode-mcp-auto-allower"
let githubURL = "https://github.com/bennokress/xcode-mcp-auto-allower"
VEOF

# ---------------------------------------------------------------------------
# Step 3: Compile binary
# ---------------------------------------------------------------------------
echo "    Compiling..."
swiftc -O "${REPO_DIR}/Sources/xcode-mcp-allower.swift" "${BUILD_DIR}/Version.swift" \
    -o "${BUILD_DIR}/${BINARY_NAME}"
echo "    Compiled successfully."

# ---------------------------------------------------------------------------
# Step 4: Create .app bundle
# ---------------------------------------------------------------------------
echo "==> Creating app bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "${BUILD_DIR}/${BINARY_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"

ICON_ENTRIES=""
if $ICON_COMPILED; then
    cp "${BUILD_DIR}/App Icon.icns" "${APP_BUNDLE}/Contents/Resources/"
    cp "${BUILD_DIR}/Assets.car" "${APP_BUNDLE}/Contents/Resources/"
    ICON_ENTRIES="<key>CFBundleIconFile</key>
    <string>App Icon</string>
    <key>CFBundleIconName</key>
    <string>App Icon</string>"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLISTEOF
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
echo "    App bundle created."

# ---------------------------------------------------------------------------
# Step 5: Code sign the .app bundle
# ---------------------------------------------------------------------------
if [ -z "${DEVELOPER_ID:-}" ]; then
    # Auto-detect Developer ID Application identity
    DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)
fi

if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Signing with: ${DEVELOPER_ID}"
    codesign --force --options runtime --sign "${DEVELOPER_ID}" --timestamp "${APP_BUNDLE}"
    echo "    App bundle signed."
else
    echo "==> WARNING: No Developer ID found. Signing ad-hoc (not suitable for distribution)."
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 6: Create DMG
# ---------------------------------------------------------------------------
DMG_NAME="Xcode.MCP.Auto-Allower-${VERSION}"
DMG_PATH="${DIST_DIR}/${DMG_NAME}.dmg"
DMG_TEMP="${BUILD_DIR}/${DMG_NAME}-temp.dmg"

DMG_BG="${REPO_DIR}/Assets/dmg-background.png"

echo "==> Creating DMG..."
rm -f "$DMG_PATH" "$DMG_TEMP"

# Create temporary writable DMG
hdiutil create -size 50m -fs HFS+ -volname "${APP_NAME}" "$DMG_TEMP" -quiet

# Mount it — volume name is known, so construct the path directly
hdiutil attach "$DMG_TEMP" -readwrite -quiet
MOUNT_POINT="/Volumes/${APP_NAME}"

echo "    Mounted at: ${MOUNT_POINT}"

# Copy app and create Applications symlink
cp -R "${APP_BUNDLE}" "${MOUNT_POINT}/"
ln -s /Applications "${MOUNT_POINT}/Applications"

# Set up background image
if [ -f "$DMG_BG" ]; then
    mkdir -p "${MOUNT_POINT}/.background"
    cp "$DMG_BG" "${MOUNT_POINT}/.background/background.png"
    echo "    Background image copied."
fi

# Configure Finder window appearance via AppleScript
echo "    Configuring window appearance..."
osascript <<ASEOF
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 880, 540}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {155, 170}
        set position of item "Applications" of container window to {625, 170}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
ASEOF
echo "    Window appearance configured."

# Sync filesystem changes and unmount
sync
hdiutil detach "$MOUNT_POINT" -quiet

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_PATH" -quiet
rm -f "$DMG_TEMP"
echo "    DMG created: ${DMG_PATH}"

# ---------------------------------------------------------------------------
# Step 7: Sign the DMG
# ---------------------------------------------------------------------------
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Signing DMG..."
    codesign --force --sign "${DEVELOPER_ID}" --timestamp "$DMG_PATH"
    echo "    DMG signed."
fi

# ---------------------------------------------------------------------------
# Step 8 & 9: Notarize and staple
# ---------------------------------------------------------------------------
NOTARIZE_CMD=""
if [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
    # CI mode: credentials via env vars
    NOTARIZE_CMD="xcrun notarytool submit \"$DMG_PATH\" --apple-id \"$APPLE_ID\" --team-id \"$TEAM_ID\" --password \"$APP_PASSWORD\" --wait"
elif xcrun notarytool history --keychain-profile "notarytool" >/dev/null 2>&1; then
    # Local mode: keychain profile
    NOTARIZE_CMD="xcrun notarytool submit \"$DMG_PATH\" --keychain-profile \"notarytool\" --wait"
fi

if [ -n "$NOTARIZE_CMD" ]; then
    echo "==> Submitting for notarization..."
    eval "$NOTARIZE_CMD"

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "    Notarization complete."
else
    echo "==> Skipping notarization (no keychain profile 'notarytool' and no APPLE_ID/TEAM_ID/APP_PASSWORD env vars)."
fi

# ---------------------------------------------------------------------------
# Clean up build directory
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"

echo ""
echo "==> Done! DMG ready at:"
echo "    ${DMG_PATH}"
echo ""
echo "    Verify signing:      codesign -dv --verbose=4 '${DMG_PATH}'"
echo "    Verify notarization: xcrun stapler validate '${DMG_PATH}'"
