# Xcode MCP Auto-Allower

A lightweight macOS daemon that automatically approves Xcode's MCP permission dialogs — for any AI coding assistant.

## The Problem

Xcode 26.3 introduced MCP server support, but every connection attempt triggers a permission dialog that must be manually approved. If you're using AI coding tools (Claude Code, GitHub Copilot, Cursor, Windsurf, etc.) that connect via MCP, these dialogs pop up constantly and break your flow.

## The Solution

This daemon uses `AXObserver` to watch for Xcode's MCP permission dialogs and automatically clicks "Allow". Detection works by matching the dialog's body text (must contain "Xcode") combined with the button pattern ("Allow" + "Don't Allow") — the exact signature of MCP permission sheets. Since the dialog text is identical across all MCP agents (only the tool name varies), this works universally without hard-coding agent names.

The daemon is fully event-driven via Accessibility notifications — no polling, no timers, virtually zero resource usage while idle.

## Requirements

- macOS 26 (Tahoe)
- Xcode 26.3+

## Install

1. Download the latest DMG from [Releases](https://github.com/bennokress/xcode-mcp-auto-allower/releases)
2. Open the DMG and drag **Xcode MCP Auto-Allower** to `/Applications`
3. Launch the app once
4. Grant **Accessibility** permission when prompted (System Settings > Privacy & Security > Accessibility)

That's it — the daemon installs its LaunchAgent automatically and runs on every login.

## Management Window

Open **Xcode MCP Auto-Allower** from `/Applications` (or Spotlight) to access:

- **Accessibility status** — live indicator showing whether the permission is granted
- **Open Accessibility Settings** — deep-links to the right pane
- **Check for Updates** — queries the GitHub Releases API, downloads and installs the latest DMG
- **Reinstall LaunchAgent** — rewrites and reloads the LaunchAgent (troubleshooting)
- **Uninstall** — stops the daemon and removes the app, LaunchAgent, and all related files

The daemon runs silently via the LaunchAgent. The management window only appears when you explicitly open the app — it uses `NSApp.setActivationPolicy(.accessory)` so it stays out of the Dock.

## Auto-Update

The app checks [github.com/bennokress/xcode-mcp-auto-allower/releases](https://github.com/bennokress/xcode-mcp-auto-allower/releases) for new versions tagged with semver (e.g. `v1.1.0`). Updates download the latest DMG, swap the app in place, and relaunch automatically.

## Uninstall

From the management window, click **Uninstall**. This removes the app bundle, LaunchAgent, log file, config, and resets the Accessibility TCC entry.

## How It Works

1. The daemon registers an `AXObserver` on each running Xcode process (matched by bundle ID `com.apple.dt.Xcode`)
2. It listens for `kAXWindowCreatedNotification` and `kAXFocusedWindowChangedNotification`
3. When fired, it scans the window's `AXChildren` for `AXStaticText` (body) and `AXButton` elements
4. If the body text contains "Xcode" **and** the window has both an "Allow" and a "Don't Allow" button — it's an MCP permission dialog
5. It calls `AXUIElementPerformAction(kAXPressAction)` on the "Allow" button
6. Observers are attached/detached dynamically as Xcode launches/terminates via `NSWorkspace` notifications

All Xcode variants (stable, betas like `Xcode-26.3.0.app`) share the bundle ID `com.apple.dt.Xcode`, so they're all handled.

## Supported Languages

The daemon matches these localized button labels:

| Language | Allow    | Don't Allow      |
|----------|----------|------------------|
| English  | Allow    | Don't Allow      |
| German   | Erlauben | Nicht erlauben   |

To add more languages, edit the `allowLabels` / `denyLabels` sets at the top of [`Sources/xcode-mcp-allower.swift`](Sources/xcode-mcp-allower.swift).

## Logs

```bash
tail -f ~/Library/Logs/xcode-mcp-allower.log
```

## App Icon

The app icon is an Xcode 26 Icon Composer package (`Assets/App Icon.icon/`). During build, `actool` compiles it into `Assets.car` with Liquid Glass rendering. To customize, edit the `.icon` package in Icon Composer and rebuild.

## Troubleshooting

**Daemon not running?**
```bash
launchctl list | grep xcode-mcp-allower
```
If no PID is shown, open the app and click **Reinstall LaunchAgent**, or check the log file for errors.

**Accessibility not granted?**
Open the app — the status indicator shows live permission state with a direct link to the settings pane.

**Dialog not being clicked?**
Check the log. If a dialog is detected but no button matches, add your language's "Allow"/"Don't Allow" equivalents to the label sets in the source.

## Development

For local development (compiles from source, no signing):

```bash
git clone https://github.com/bennokress/xcode-mcp-auto-allower.git
cd xcode-mcp-auto-allower
./Scripts/install.sh
```

Requires Xcode Command Line Tools (`xcode-select --install`).

### Building a Release DMG

```bash
# Set signing & notarization credentials
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export TEAM_ID="TEAMID"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # or @keychain:notarytool

./Scripts/build-dmg.sh
```

The signed + notarized DMG is output to `Distribution/`.

---

<sub>This project is not affiliated with, endorsed by, or connected to Apple Inc. "Xcode", "macOS", and "Mac" are trademarks of Apple Inc., registered in the U.S. and other countries. All trademark rights belong to their respective owners.</sub>
