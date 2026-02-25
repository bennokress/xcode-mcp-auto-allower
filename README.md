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
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/bennokress/xcode-mcp-auto-allower.git
cd xcode-mcp-auto-allower
./install.sh
```

The install script will:
1. Compile the `.icon` package via `actool` (Liquid Glass icon)
2. Compile the Swift source via `swiftc -O` with the version from `git describe --tags`
3. Create an `.app` bundle at `~/Applications/Xcode MCP Auto-Allower.app`
4. Install a LaunchAgent (`com.local.xcode-mcp-allower`) with `KeepAlive` and `RunAtLoad`

**After installing, grant Accessibility permission** to "Xcode MCP Auto-Allower" in System Settings > Privacy & Security > Accessibility.

## Management Window

Open `Xcode MCP Auto-Allower.app` from `~/Applications` (or Spotlight) to access:

- **Accessibility status** — live indicator showing whether the permission is granted
- **Open Accessibility Settings** — deep-links to the right pane
- **Check for Updates** — queries the GitHub Releases API, offers one-click `git pull && ./install.sh`
- **Reinstall** — recompiles and reinstalls from the local clone
- **Uninstall** — stops the daemon and removes all installed files

The daemon runs silently via the LaunchAgent. The management window only appears when you explicitly open the app — it uses `NSApp.setActivationPolicy(.accessory)` so it stays out of the Dock.

## Auto-Update

The app checks [github.com/bennokress/xcode-mcp-auto-allower/releases](https://github.com/bennokress/xcode-mcp-auto-allower/releases) for new versions tagged with semver (e.g. `v1.1.0`). Updates run `git pull && ./install.sh` from the stored repo path (`~/.config/xcode-mcp-allower/repo-path`).

You can also update manually:

```bash
cd xcode-mcp-auto-allower
git pull
./install.sh
```

## Uninstall

From the management window, click **Uninstall**. Or from the terminal:

```bash
./uninstall.sh
```

This removes the app bundle, LaunchAgent, log file, config, and resets the Accessibility TCC entry.

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

The app icon is an Xcode 26 Icon Composer package (`App Icon.icon/`). During install, `actool` compiles it into `Assets.car` with Liquid Glass rendering. To customize, edit the `.icon` package in Icon Composer and re-run `./install.sh`.

## Troubleshooting

**Daemon not running?**
```bash
launchctl list | grep xcode-mcp-allower
```
If no PID is shown, check the log file for errors.

**Accessibility not granted?**
Open the app — the status indicator shows live permission state with a direct link to the settings pane.

**Dialog not being clicked?**
Check the log. If a dialog is detected but no button matches, add your language's "Allow"/"Don't Allow" equivalents to the label sets in the source.

**Reinstalling?**
Open the app and click **Reinstall**, or run `./install.sh` from the terminal.

---

<sub>This project is not affiliated with, endorsed by, or connected to Apple Inc. "Xcode", "macOS", and "Mac" are trademarks of Apple Inc., registered in the U.S. and other countries. All trademark rights belong to their respective owners.</sub>
