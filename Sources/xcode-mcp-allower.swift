import Cocoa
import ApplicationServices
import SwiftUI
import UserNotifications

/// `appVersion`, `githubRepo`, and `githubURL` are defined in the build-generated `Version.swift`.

// MARK: - Constants

/// The LaunchAgent bundle identifier used for launchctl registration and plist naming.
let label = "com.bennokress.xcode-mcp-allower"

/// The bundle identifier used to identify Xcode in running application queries.
let xcodeBundleID = "com.apple.dt.Xcode"

/// The path to the daemon's log file.
let logFile = NSHomeDirectory() + "/Library/Logs/xcode-mcp-allower.log"

/// Checks whether this process has Accessibility permission by querying the TCC database directly.
///
/// Unlike plain `AXIsProcessTrusted()`, passing an options dictionary forces macOS to
/// re-read the database instead of returning a stale cached value within the same process.
func isAccessibilityEnabled() -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary)
}

// MARK: - Daemon Logic

/// Maps Xcode process IDs to their corresponding accessibility observers for cleanup on termination.
var activeObservers: [pid_t: AXObserver] = [:]

/// Localized button labels for the "Allow" action in Xcode's MCP permission dialog.
let allowLabels: Set<String> = ["Allow", "Erlauben"]

/// Localized button labels for the "Don't Allow" action in Xcode's MCP permission dialog.
let denyLabels: Set<String> = ["Don\u{2019}t Allow", "Don't Allow", "Nicht erlauben"]

/// Scans Xcode's windows for an MCP permission dialog and clicks "Allow" if found.
///
/// Identifies the dialog by checking for body text mentioning "Xcode" combined with
/// matching Allow/Don't Allow button pairs. Respects the paused state.
/// - Parameter app: The accessibility element representing the Xcode application.
func clickAllowIfPresent(in app: AXUIElement) {
    if UserDefaults.standard.bool(forKey: "launchAgentPaused") { return }

    var windowsRef: CFTypeRef?
    let axResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
    guard axResult == .success, let windows = windowsRef as? [AXUIElement] else {
        NSLog("[xcode-mcp-allower] Cannot read Xcode windows (AXError=%d). AXIsProcessTrusted=%d.",
              axResult.rawValue, isAccessibilityEnabled())
        return
    }

    for window in windows {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef)
        let children = (childrenRef as? [AXUIElement]) ?? []

        // Collect buttons and body text in one pass
        var buttons: [(title: String, element: AXUIElement)] = []
        var bodyText = ""

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == "AXButton" {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                buttons.append((title: titleRef as? String ?? "", element: child))
            } else if role == "AXStaticText" {
                var valueRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
                bodyText += (valueRef as? String ?? "") + " "
            }
        }

        // MCP permission dialog: body mentions "Xcode" + has Allow/Don't Allow buttons.
        // The dialog text is identical across all MCP agents — only the tool name varies.
        guard bodyText.contains("Xcode") else { continue }
        let allowButton = buttons.first { allowLabels.contains($0.title) }
        let hasDeny = buttons.contains { denyLabels.contains($0.title) }
        guard let allow = allowButton, hasDeny else { continue }

        NSLog("[xcode-mcp-allower] Found permission dialog: %@",
              bodyText.trimmingCharacters(in: .whitespacesAndNewlines))

        let result = AXUIElementPerformAction(allow.element, kAXPressAction as CFString)
        NSLog("[xcode-mcp-allower] Clicked '%@' (result: %d).", allow.title, result.rawValue)
        return
    }
}

/// Attaches an accessibility observer to a running Xcode instance to watch for new windows.
///
/// Registers for window-created and focus-changed notifications on the main run loop,
/// and performs an immediate scan for any existing permission dialogs.
/// - Parameter app: The running Xcode application to observe.
func setupObserver(for app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard activeObservers[pid] == nil else { return }

    let appElement = AXUIElementCreateApplication(pid)

    let callback: AXObserverCallback = { _, _, notification, _ in
        NSLog("[xcode-mcp-allower] AX notification: %@", notification as String)
        for xcode in NSWorkspace.shared.runningApplications where xcode.bundleIdentifier == xcodeBundleID {
            clickAllowIfPresent(in: AXUIElementCreateApplication(xcode.processIdentifier))
        }
    }

    var observer: AXObserver?
    guard AXObserverCreate(pid, callback, &observer) == .success, let axObserver = observer else {
        NSLog("[xcode-mcp-allower] Failed to create AXObserver for Xcode (pid %d).", pid)
        return
    }

    AXObserverAddNotification(axObserver, appElement, kAXWindowCreatedNotification as CFString, nil)
    AXObserverAddNotification(axObserver, appElement, kAXFocusedWindowChangedNotification as CFString, nil)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
    activeObservers[pid] = axObserver

    clickAllowIfPresent(in: appElement)
    NSLog("[xcode-mcp-allower] Now observing Xcode (pid %d).", pid)
}

/// Removes and cleans up the accessibility observer for a terminated Xcode process.
/// - Parameter pid: The process identifier of the Xcode instance that was terminated.
func teardownObserver(for pid: pid_t) {
    if let axObserver = activeObservers.removeValue(forKey: pid) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        NSLog("[xcode-mcp-allower] Stopped observing Xcode (pid %d).", pid)
    }
}

/// Starts the background daemon that monitors Xcode launches and terminations.
///
/// Sets up workspace notification observers to automatically attach/detach
/// accessibility observers as Xcode instances come and go. Also attaches
/// to any Xcode instances that are already running.
func startDaemon() {
    let workspace = NSWorkspace.shared
    let notificationCenter = workspace.notificationCenter

    notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == xcodeBundleID else { return }
        NSLog("[xcode-mcp-allower] Xcode launched (pid %d).", app.processIdentifier)
        setupObserver(for: app)
    }

    notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == xcodeBundleID else { return }
        teardownObserver(for: app.processIdentifier)
    }

    for app in workspace.runningApplications where app.bundleIdentifier == xcodeBundleID {
        NSLog("[xcode-mcp-allower] Xcode already running (pid %d).", app.processIdentifier)
        setupObserver(for: app)
    }

    if isAccessibilityEnabled() {
        NSLog("[xcode-mcp-allower] Accessibility permission: GRANTED")
    } else {
        NSLog("[xcode-mcp-allower] WARNING: Accessibility permission NOT granted!")
    }

    NSLog("[xcode-mcp-allower] Daemon started (v%@). Watching for Xcode MCP permission dialogs.", appVersion)
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

// MARK: - Update Progress UI

/// Observable model driving the update progress view during downloads.
@Observable
class UpdateProgress {
    var progress: Double = 0
    var status: String = "Establishing connection\u{2026}"
}

/// SwiftUI view showing a tinted progress bar and status label for the update alert.
struct UpdateProgressView: View {
    var model: UpdateProgress

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.2))
                    if model.progress > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(width: max(6, geo.size.width * model.progress))
                    }
                }
            }
            .frame(height: 6)

            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
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

// MARK: - Settings View

/// A small circle used as a status indicator.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
}

/// The main settings window content.
struct SettingsView: View {
    @Bindable var appState: AppState
    @AppStorage("includeBetaUpdates") private var includeBetaUpdates = false
    @AppStorage("resumeAfterReboot") private var resumeAfterReboot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            descriptionSection
            Divider()
            accessibilitySection
            Divider()
            launchAgentSection
            managementSection
            Divider()
            updateSection
            Divider()
            actionsSection
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .task {
            while !Task.isCancelled {
                appState.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { appState.refreshStatus() }
        .alert(
            appState.activeAlert?.title ?? "",
            isPresented: $appState.isAlertPresented,
            presenting: appState.activeAlert
        ) { alert in
            alertActions(for: alert)
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("Xcode MCP Auto-Allower")
                    .font(.system(size: 20, weight: .semibold))
                Text("Benno Kress \u{2022} Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var descriptionSection: some View {
        Text("This app automatically approves Xcode\u{2019}s MCP permission dialogs " +
             "when AI coding assistants connect, so you don\u{2019}t have to " +
             "click \u{201C}Allow\u{201D} every single time.")
            .font(.system(size: 13))
    }

    private var accessibilitySection: some View {
        Group {
            HStack(spacing: 8) {
                StatusDot(color: appState.isAccessibilityGranted ? .green : .red)
                Text(appState.isAccessibilityGranted ? "Accessibility: Granted" : "Accessibility: Not Granted")
                    .font(.system(size: 13))
            }

            Text("This app needs Accessibility access in System Settings to detect and " +
                 "click Xcode\u{2019}s permission dialogs automatically. If the status " +
                 "above shows \u{201C}Not Granted\u{201D}, click the button below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Open Accessibility Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    private var launchAgentSection: some View {
        Group {
            HStack(spacing: 8) {
                StatusDot(color: launchAgentDotColor)
                Text(launchAgentLabelText)
                    .font(.system(size: 13))
            }

            Text(launchAgentDescriptionText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var managementSection: some View {
        HStack(spacing: 12) {
            Button(appState.launchAgentStatus == .running ? "Pause" : "Resume") {
                appState.togglePauseResume()
            }
            .disabled(appState.launchAgentStatus == .notFound)

            Toggle("Resume after system reboot", isOn: $resumeAfterReboot)
                .toggleStyle(.checkbox)
                .disabled(appState.launchAgentStatus == .notFound)
                .onChange(of: resumeAfterReboot) { _, newValue in
                    appState.rebootCheckboxChanged(newValue)
                }
        }
    }

    private var updateSection: some View {
        Group {
            HStack(spacing: 8) {
                Image("github.fill")
                    .renderingMode(.template)
                    .font(.system(size: 10))
                    .frame(width: 10, height: 10)
                Text("Updates")
                    .font(.system(size: 13))
            }

            Text("This app is maintained on [GitHub by Benno Kress](https://github.com/\(githubRepo)). It checks for updates once per day automatically as long as the LaunchAgent is running, but you can trigger a check manually using the button below.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Check for Updates") { appState.checkForUpdates() }
                Toggle("Include beta versions", isOn: $includeBetaUpdates)
                    .toggleStyle(.checkbox)
                    .onChange(of: includeBetaUpdates) { _, newValue in
                        appState.betaToggleChanged(newValue)
                    }
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button("Reinstall LaunchAgent") {
                appState.activeAlert = .reinstallConfirmation
            }

            Spacer()

            Button("Uninstall") {
                appState.activeAlert = .uninstallConfirmation
            }
            .tint(.red)
        }
    }

    // MARK: Helpers

    private var launchAgentDotColor: Color {
        switch appState.launchAgentStatus {
        case .running: .green
        case .paused: .orange
        case .notFound: .gray
        }
    }

    private var launchAgentLabelText: String {
        switch appState.launchAgentStatus {
        case .running: "LaunchAgent: Running"
        case .paused: "LaunchAgent: Paused"
        case .notFound: "LaunchAgent: Not Found"
        }
    }

    private var launchAgentDescriptionText: String {
        switch appState.launchAgentStatus {
        case .running:
            "The background watcher is active and will automatically approve Xcode\u{2019}s MCP permission dialogs."
        case .paused:
            "The background watcher is paused. Permission dialogs will not be approved automatically until resumed."
        case .notFound:
            "The background watcher is not installed. Click Reinstall to set it up again."
        }
    }

    @ViewBuilder
    private func alertActions(for alert: ActiveAlert) -> some View {
        switch alert {
        case .error, .info:
            Button("OK") {}
        case .reinstallConfirmation:
            Button("Reinstall") { appState.reinstallLaunchAgent() }
            Button("Cancel", role: .cancel) {}
        case .uninstallConfirmation:
            Button("Uninstall", role: .destructive) { appState.uninstall() }
            Button("Cancel", role: .cancel) {}
        case .updateAvailable:
            Button("Update") { appState.performUpdate() }
            Button("Later", role: .cancel) {}
        }
    }
}

// MARK: - Download Delegate

/// Bridges `URLSessionDownloadDelegate` callbacks to closures for progress tracking and completion handling.
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onComplete: ((URL) -> Void)?
    var onError: (() -> Void)?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onComplete?(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        onError?()
    }
}

// MARK: - App Delegate

/// The main application delegate handling window management, daemon lifecycle, and updates.
///
/// Runs as a background daemon (via `--background`) or as a regular app with a settings window.
/// Manages the LaunchAgent, monitors accessibility status, and checks for updates on GitHub.
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var updateCheckTimer: Timer?

    /// Stores the release JSON from a background update check so it can be shown when the user taps the notification.
    var pendingUpdateJSON: [String: Any]?

    /// Whether the app was launched with `--background` as a headless daemon.
    var isBackgroundMode: Bool = false

    /// The centralized UI state model observed by the SwiftUI settings view.
    let appState = AppState()

    /// Whether beta (prerelease) versions should be included in update checks. Persisted in UserDefaults.
    var includeBetaUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "includeBetaUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "includeBetaUpdates") }
    }

    /// Whether the daemon is currently paused. Persisted in UserDefaults.
    var launchAgentPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "launchAgentPaused") }
        set { UserDefaults.standard.set(newValue, forKey: "launchAgentPaused") }
    }

    /// Whether the daemon should automatically resume after a system reboot while paused. Persisted in UserDefaults.
    var resumeAfterReboot: Bool {
        get { UserDefaults.standard.bool(forKey: "resumeAfterReboot") }
        set { UserDefaults.standard.set(newValue, forKey: "resumeAfterReboot") }
    }

    /// Custom entry point that configures the activation policy based on `--background` flag.
    ///
    /// In background mode the app runs as an accessory (no dock icon) and resets the paused state.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        let isBackground = CommandLine.arguments.contains("--background")
        app.setActivationPolicy(isBackground ? .accessory : .regular)
        delegate.isBackgroundMode = isBackground
        if isBackground {
            delegate.launchAgentPaused = false
        }
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        ensureLaunchAgent()
        startDaemon()

        // Wire SwiftUI action closures
        appState.togglePauseResume = { [weak self] in self?.togglePauseResume() }
        appState.reinstallLaunchAgent = { [weak self] in self?.doReinstallLaunchAgent() }
        appState.uninstall = { [weak self] in self?.doUninstall() }
        appState.checkForUpdates = { [weak self] in self?.checkForUpdates(silent: false) }
        appState.performUpdate = { [weak self] in
            guard let self, let json = self.pendingUpdateJSON else { return }
            self.performUpdate(json: json)
        }
        appState.rebootCheckboxChanged = { [weak self] newValue in
            self?.handleRebootCheckboxChanged(newValue)
        }
        appState.betaToggleChanged = { [weak self] newValue in
            self?.includeBetaUpdates = newValue
            self?.checkForUpdates(silent: true)
        }

        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self

        // Schedule background update checks every 24 hours
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.checkForUpdatesInBackground()
        }

        // Run an immediate background check
        checkForUpdatesInBackground()

        if !isBackgroundMode {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if isBackgroundMode {
            NSApp.setActivationPolicy(.regular)
        }
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isBackgroundMode
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        showWindow()
        if let json = pendingUpdateJSON {
            let latest = releaseVersion(from: json)
            appState.activeAlert = .updateAvailable(latest)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Main Menu

    /// Sets up a minimal main menu so that standard keyboard shortcuts (e.g. CMD+Q) work
    /// even though the app uses `LSUIElement` and has no persistent menu bar.
    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Xcode MCP Auto-Allower", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Window Management

    /// Creates the settings window if needed and brings it to front.
    func showWindow() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if isBackgroundMode {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Window Creation

    /// Creates the settings window with a SwiftUI content view.
    func createWindow() {
        let hostingView = NSHostingView(rootView: SettingsView(appState: appState))
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Xcode MCP Auto-Allower"
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.contentView = hostingView
        newWindow.setContentSize(hostingView.fittingSize)
        newWindow.center()
        self.window = newWindow
    }

    // MARK: Actions

    /// Toggles the daemon between paused and running states.
    func togglePauseResume() {
        if appState.launchAgentStatus == .running {
            run("/bin/launchctl", "bootout", "gui/\(getuid())/\(label)")
            launchAgentPaused = true
            if !resumeAfterReboot {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath())
            }
        } else {
            ensureLaunchAgent()
            launchAgentPaused = false
        }
        appState.refreshStatus()
    }

    /// Handles the "Resume after system reboot" toggle change.
    func handleRebootCheckboxChanged(_ newValue: Bool) {
        resumeAfterReboot = newValue
        if launchAgentPaused {
            if resumeAfterReboot {
                writeLaunchAgentPlist()
            } else {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath())
            }
        }
    }

    /// Force-reinstalls the LaunchAgent from scratch. Called from the confirmation alert action.
    func doReinstallLaunchAgent() {
        let plistPath = launchAgentPlistPath()
        try? FileManager.default.removeItem(atPath: plistPath)
        ensureLaunchAgent()
        launchAgentPaused = false
        appState.refreshStatus()
        DispatchQueue.main.async {
            self.appState.activeAlert = .info("Background watcher reinstalled successfully.")
        }
    }

    /// Completely removes the app, LaunchAgent, logs, config, and Accessibility permissions.
    /// Called from the confirmation alert action.
    func doUninstall() {
        let plistPath = launchAgentPlistPath()
        let configDirectory = NSHomeDirectory() + "/.config/xcode-mcp-allower"
        let appPath = Bundle.main.bundlePath

        // 1. Stop daemon
        run("/bin/launchctl", "bootout", "gui/\(getuid())/\(label)")

        // 2. Remove LaunchAgent plist
        try? FileManager.default.removeItem(atPath: plistPath)

        // 3. Remove log file
        try? FileManager.default.removeItem(atPath: logFile)

        // 4. Remove config directory
        try? FileManager.default.removeItem(atPath: configDirectory)

        // 5. Remove ~/Library artefacts (Caches, HTTPStorages, Preferences)
        let home = NSHomeDirectory()
        for subpath in [
            "/Library/Caches/\(label)",
            "/Library/HTTPStorages/\(label)",
            "/Library/Preferences/\(label).plist",
        ] {
            try? FileManager.default.removeItem(atPath: home + subpath)
        }

        // 6. Reset Accessibility permission
        run("/usr/bin/tccutil", "reset", "Accessibility", label)

        // 7. Spawn detached script to delete the .app bundle after this process exits, then quit
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf \(shellQuote(appPath))
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        NSApp.terminate(nil)
    }

    // MARK: Update Check (Interactive)

    /// Fetches the latest releases from GitHub and shows an update alert if a newer version exists.
    /// - Parameter silent: When `true`, suppresses "up to date" and error messages.
    func checkForUpdates(silent: Bool = false) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases")!
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if error != nil {
                    if !silent { self.appState.activeAlert = .error("Unable to check for updates. Please check your internet connection.") }
                    return
                }

                guard let data,
                      let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    if !silent { self.appState.activeAlert = .error("Unable to check for updates. Please try again later.") }
                    return
                }

                guard let json = self.firstMatchingRelease(from: releases) else {
                    if !silent { self.appState.activeAlert = .info("You\u{2019}re on the latest version (\(appVersion)).") }
                    return
                }

                let latest = releaseVersion(from: json)

                if isNewerVersion(latest, than: appVersion) {
                    self.pendingUpdateJSON = json
                    self.appState.activeAlert = .updateAvailable(latest)
                } else {
                    if !silent { self.appState.activeAlert = .info("You\u{2019}re on the latest version (\(appVersion)).") }
                }
            }
        }.resume()
    }

    // MARK: Update Check (Background)

    /// Silently checks for updates and posts a system notification if a newer version is available.
    ///
    /// Skipped when the daemon is paused. Stores the release JSON in ``pendingUpdateJSON``
    /// so the update can be presented when the user taps the notification.
    func checkForUpdatesInBackground() {
        if launchAgentPaused { return }

        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, error == nil,
                  let data,
                  let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let json = self.firstMatchingRelease(from: releases) else { return }

            let latest = releaseVersion(from: json)

            guard isNewerVersion(latest, than: appVersion) else { return }

            DispatchQueue.main.async {
                self.pendingUpdateJSON = json
            }

            let content = UNMutableNotificationContent()
            content.title = "Update Available"
            content.body = "\(latest) is ready to install."
            content.sound = .default

            let request = UNNotificationRequest(identifier: "update-available", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }.resume()
    }

    // MARK: Release Filtering

    /// Returns the first non-draft release that has a downloadable DMG asset,
    /// optionally filtering out prereleases.
    /// - Parameter releases: An array of GitHub release JSON dictionaries.
    /// - Returns: The first matching release, or `nil` if none qualify.
    func firstMatchingRelease(from releases: [[String: Any]]) -> [String: Any]? {
        for release in releases {
            if release["draft"] as? Bool == true { continue }
            if !includeBetaUpdates && release["prerelease"] as? Bool == true { continue }
            guard let assets = release["assets"] as? [[String: Any]],
                  assets.contains(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") })
            else { continue }
            return release
        }
        return nil
    }

    // MARK: Update Installation

    /// Downloads and installs the update described by the given release JSON.
    ///
    /// Downloads the `.dmg` asset, mounts it, then spawns a detached shell script that
    /// replaces the current app bundle after this process exits and relaunches.
    /// - Parameter json: A GitHub release JSON dictionary containing the `assets` array.
    func performUpdate(json: [String: Any]) {
        let latest = releaseVersion(from: json)

        // Find the .dmg asset URL from the release JSON
        guard let assets = json["assets"] as? [[String: Any]],
              let dmgAsset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
              let downloadURLString = dmgAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            appState.activeAlert = .error("This update isn\u{2019}t available for download yet. Please try again later.")
            return
        }

        // Build progress UI
        let progressAlert = NSAlert()
        progressAlert.messageText = "Updating to \(latest)\u{2026}"
        progressAlert.informativeText = ""
        progressAlert.addButton(withTitle: "Cancel")

        let progressModel = UpdateProgress()
        let hostingView = NSHostingView(rootView: UpdateProgressView(model: progressModel))
        progressAlert.accessoryView = hostingView

        // Match the Cancel button's visible bezel width
        progressAlert.window.layoutIfNeeded()
        if let button = progressAlert.buttons.first, let cell = button.cell {
            let drawingRect = cell.drawingRect(forBounds: button.bounds)
            hostingView.frame.size = hostingView.fittingSize
            hostingView.frame.size.width = drawingRect.width
        }

        // State shared between the download callbacks and the cancel handler
        var isCancelled = false
        var downloadSession: URLSession?
        var downloadTask: URLSessionDownloadTask?
        var activeMountPoint: String?
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-mcp-allower-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let dmgPath = temporaryDirectory.appendingPathComponent("update.dmg")

        let abortUpdate = { [weak self] in
            DispatchQueue.main.async {
                guard !isCancelled else { return }
                NSApp.stopModal()
                self?.appState.activeAlert = .error("The update could not be installed. Please try again later.")
            }
        }

        // Set up download delegate
        let delegate = DownloadDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadSession = session

        delegate.onProgress = { fraction in
            DispatchQueue.main.async {
                guard !isCancelled else { return }
                progressModel.progress = fraction
                progressModel.status = "Downloading\u{2026} \(Int(fraction * 100))%"
            }
        }

        delegate.onComplete = { [weak self] location in
            guard let self, !isCancelled else { return }

            // Copy downloaded file to our temp directory
            do {
                try FileManager.default.moveItem(at: location, to: dmgPath)
            } catch {
                abortUpdate()
                return
            }

            DispatchQueue.main.async {
                guard !isCancelled else { return }
                progressModel.status = "Preparing installation\u{2026}"
            }

            // Mount the DMG
            let mountProcess = Process()
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountProcess.arguments = ["attach", dmgPath.path, "-nobrowse", "-readonly", "-quiet"]
            mountProcess.standardOutput = FileHandle.nullDevice
            mountProcess.standardError = FileHandle.nullDevice
            try? mountProcess.run()
            mountProcess.waitUntilExit()

            guard !isCancelled else { return }

            // Find the .app in the mount point
            let volumesDirectory = "/Volumes"
            guard let volumes = try? FileManager.default.contentsOfDirectory(atPath: volumesDirectory) else {
                abortUpdate()
                return
            }

            var mountedAppPath: String?
            for volume in volumes {
                let volumePath = "\(volumesDirectory)/\(volume)"
                let candidateApp = "\(volumePath)/Xcode MCP Auto-Allower.app"
                if FileManager.default.fileExists(atPath: candidateApp) {
                    mountedAppPath = candidateApp
                    activeMountPoint = volumePath
                    break
                }
            }

            guard let sourceApp = mountedAppPath, let mount = activeMountPoint else {
                abortUpdate()
                return
            }

            guard !isCancelled else { return }

            // Spawn detached updater script
            let currentAppPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            let plistPath = launchAgentPlistPath()
            let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                rm -rf \(self.shellQuote(currentAppPath))
                cp -R \(self.shellQuote(sourceApp)) \(self.shellQuote((currentAppPath as NSString).deletingLastPathComponent))/
                hdiutil detach \(self.shellQuote(mount)) -quiet 2>/dev/null || true
                rm -rf \(self.shellQuote(temporaryDirectory.path))
                sleep 0.5
                open \(self.shellQuote(currentAppPath))
                sleep 2
                /bin/launchctl bootstrap gui/$(id -u) \(self.shellQuote(plistPath))
                """

            DispatchQueue.main.async {
                guard !isCancelled else { return }
                progressModel.status = "Quitting version \(appVersion)\u{2026}"
                progressModel.progress = 1

                NSApp.stopModal()

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-c", script]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()

                // Bootout LaunchAgent before terminating so KeepAlive doesn't restart us
                run("/bin/launchctl", "bootout", "gui/\(getuid())/\(label)")
                NSApp.terminate(nil)
            }
        }

        delegate.onError = {
            guard !isCancelled else { return }
            abortUpdate()
        }

        // Start download
        let task = session.downloadTask(with: downloadURL)
        downloadTask = task
        task.resume()

        // Block until the alert is dismissed (by Cancel button or stopModal)
        let response = progressAlert.runModal()

        // If we get here via the Cancel button, clean up
        if response == .alertFirstButtonReturn {
            isCancelled = true
            downloadTask?.cancel()
            downloadSession?.invalidateAndCancel()
            if let mount = activeMountPoint {
                run("/usr/bin/hdiutil", "detach", mount, "-quiet")
            }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: Helpers

    /// Wraps a string in single quotes with proper escaping for safe use in shell commands.
    /// - Parameter string: The string to quote.
    /// - Returns: A shell-safe single-quoted string.
    func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
