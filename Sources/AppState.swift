import Foundation
import Observation

// MARK: - Update Progress UI

/// Observable model driving the update progress view during downloads.
@Observable
class UpdateProgress {
    var progress: Double = 0
    var status: String = "Establishing connection\u{2026}"
}

// MARK: - Active Alert

/// Describes the alert currently presented in the settings window.
enum ActiveAlert: Identifiable {
    case error(String)
    case info(String)
    case reinstallConfirmation
    case uninstallConfirmation
    case updateAvailable(String)

    var id: String {
        switch self {
        case .error: "error"
        case .info: "info"
        case .reinstallConfirmation: "reinstall"
        case .uninstallConfirmation: "uninstall"
        case .updateAvailable: "update"
        }
    }

    var title: String {
        switch self {
        case .error: "Error"
        case .info: "Xcode MCP Auto-Allower"
        case .reinstallConfirmation: "Reinstall LaunchAgent?"
        case .uninstallConfirmation: "Uninstall Xcode MCP Auto-Allower?"
        case .updateAvailable: "Update Available"
        }
    }

    var message: String {
        switch self {
        case .error(let msg), .info(let msg): msg
        case .reinstallConfirmation: "Use this if the background watcher isn\u{2019}t running correctly."
        case .uninstallConfirmation: "This will remove the app and all related data from your Mac."
        case .updateAvailable(let version): "A new version is available.\n\nInstalled: \(appVersion)\nAvailable: \(version)"
        }
    }
}

// MARK: - App State

/// Centralized observable state driving the settings window UI.
@Observable
class AppState {
    var isAccessibilityGranted = false
    var launchAgentStatus: LaunchAgentStatus = .notFound
    var activeAlert: ActiveAlert?

    /// Binding helper for SwiftUI `.alert(isPresented:)`.
    var isAlertPresented: Bool {
        get { activeAlert != nil }
        set { if !newValue { activeAlert = nil } }
    }

    /// Action closures wired by AppDelegate with `[weak self]` captures.
    var togglePauseResume: () -> Void = {}
    var reinstallLaunchAgent: () -> Void = {}
    var uninstall: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var performUpdate: () -> Void = {}
    var rebootCheckboxChanged: (Bool) -> Void = { _ in }
    var betaToggleChanged: (Bool) -> Void = { _ in }

    /// Polls accessibility and LaunchAgent status from the system.
    func refreshStatus() {
        isAccessibilityGranted = isAccessibilityEnabled()
        let paused = UserDefaults.standard.bool(forKey: "launchAgentPaused")
        if paused {
            launchAgentStatus = .paused
        } else {
            launchAgentStatus = run("/bin/launchctl", "list", label) == 0 ? .running : .notFound
        }
    }
}
