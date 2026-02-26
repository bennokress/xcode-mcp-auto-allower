import Foundation

// MARK: - LaunchAgent Status

/// The current state of the background LaunchAgent.
enum LaunchAgentStatus {
    /// The LaunchAgent is registered and actively monitoring.
    case running

    /// The LaunchAgent is temporarily paused by the user.
    case paused

    /// The LaunchAgent plist is not registered with launchctl.
    case notFound
}

// MARK: - LaunchAgent Management

/// Returns the file path for the LaunchAgent plist in `~/Library/LaunchAgents/`.
func launchAgentPlistPath() -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
}

/// Writes (or overwrites) the LaunchAgent plist pointing to the current app binary.
///
/// Creates the `~/Library/LaunchAgents/` directory if it doesn't exist.
func writeLaunchAgentPlist() {
    let plistPath = launchAgentPlistPath()
    guard let binaryPath = Bundle.main.executablePath else {
        NSLog("[xcode-mcp-allower] Cannot determine executable path for LaunchAgent.")
        return
    }

    let directory = (plistPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [binaryPath, "--background"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "AssociatedBundleIdentifiers": label,
        "StandardOutPath": logFile,
        "StandardErrorPath": logFile,
    ]
    (plist as NSDictionary).write(toFile: plistPath, atomically: true)
}

/// Ensures the LaunchAgent is installed and up to date.
///
/// Compares the existing plist's binary path against the current executable. If they
/// differ (or the plist doesn't exist), writes a new plist and reloads via `launchctl`.
func ensureLaunchAgent() {
    let plistPath = launchAgentPlistPath()
    guard let binaryPath = Bundle.main.executablePath else {
        NSLog("[xcode-mcp-allower] Cannot determine executable path for LaunchAgent.")
        return
    }

    // Check if plist exists and already points to current binary
    if let existing = NSDictionary(contentsOfFile: plistPath),
       let args = existing["ProgramArguments"] as? [String],
       args.first == binaryPath {
        NSLog("[xcode-mcp-allower] LaunchAgent already installed and up to date.")
        return
    }

    NSLog("[xcode-mcp-allower] Installing/updating LaunchAgent...")

    writeLaunchAgentPlist()

    // Reload: bootout old (if any), then bootstrap new
    let uid = getuid()
    run("/bin/launchctl", "bootout", "gui/\(uid)/\(label)")
    run("/bin/launchctl", "bootstrap", "gui/\(uid)", plistPath)

    NSLog("[xcode-mcp-allower] LaunchAgent installed and loaded.")
}
