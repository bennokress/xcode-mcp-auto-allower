import ApplicationServices
import Foundation

// MARK: - Constants

/// The LaunchAgent bundle identifier used for launchctl registration and plist naming.
let label = "com.bennokress.xcode-mcp-allower"

/// The bundle identifier used to identify Xcode in running application queries.
let xcodeBundleID = "com.apple.dt.Xcode"

/// The path to the daemon's log file.
let logFile = NSHomeDirectory() + "/Library/Logs/xcode-mcp-allower.log"

// MARK: - Accessibility

/// Checks whether this process has Accessibility permission by querying the TCC database directly.
///
/// Unlike plain `AXIsProcessTrusted()`, passing an options dictionary forces macOS to
/// re-read the database instead of returning a stale cached value within the same process.
func isAccessibilityEnabled() -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
}

// MARK: - Process Helper

/// Runs a command-line tool synchronously with suppressed output.
/// - Parameters:
///   - executable: The full path to the executable (e.g. `/bin/launchctl`).
///   - arguments: The arguments to pass to the executable.
/// - Returns: The process termination status code.
@discardableResult
func run(_ executable: String, _ arguments: String...) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

// MARK: - Version Comparison

/// Extracts the semantic version string from a GitHub release JSON object.
///
/// Strips the leading "v" prefix from the tag name (e.g. "v1.2.0" becomes "1.2.0").
/// - Parameter json: A GitHub release JSON dictionary containing a `tag_name` key.
/// - Returns: The version string without the "v" prefix, or an empty string if the tag is missing.
func releaseVersion(from json: [String: Any]) -> String {
    let tagName = json["tag_name"] as? String ?? ""
    return tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
}

/// Compares two semantic version strings component by component.
/// - Parameters:
///   - remote: The remote version string (e.g. "1.3.0").
///   - local: The local version string to compare against.
/// - Returns: `true` if `remote` is newer than `local`.
func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
    let localParts = local.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(remoteParts.count, localParts.count) {
        let remoteValue = i < remoteParts.count ? remoteParts[i] : 0
        let localValue = i < localParts.count ? localParts[i] : 0
        if remoteValue != localValue { return remoteValue > localValue }
    }
    return false
}
