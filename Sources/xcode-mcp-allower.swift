import Cocoa
import ApplicationServices
import UserNotifications

/// `appVersion`, `githubRepo`, and `githubURL` are defined in the build-generated `Version.swift`.

// MARK: - Constants

/// The LaunchAgent bundle identifier used for launchctl registration and plist naming.
let label = "com.local.xcode-mcp-allower"

/// The bundle identifier used to identify Xcode in running application queries.
let xcodeBundleID = "com.apple.dt.Xcode"

/// The path to the daemon's log file.
let logFile = NSHomeDirectory() + "/Library/Logs/xcode-mcp-allower.log"

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
              axResult.rawValue, AXIsProcessTrusted())
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

    if AXIsProcessTrusted() {
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

// MARK: - App Delegate

/// The main application delegate handling window management, daemon lifecycle, and updates.
///
/// Runs as a background daemon (via `--background`) or as a regular app with a settings window.
/// Manages the LaunchAgent, monitors accessibility status, and checks for updates on GitHub.
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var accessibilityDot: NSView?
    var accessibilityLabel: NSTextField?
    var launchAgentDot: NSView?
    var launchAgentLabel: NSTextField?
    var launchAgentDescription: NSTextField?
    var pauseResumeButton: NSButton?
    var resumeAfterRebootCheckbox: NSButton?
    var statusTimer: Timer?
    var updateCheckTimer: Timer?

    /// Stores the release JSON from a background update check so it can be shown when the user taps the notification.
    var pendingUpdateJSON: [String: Any]?

    /// Whether the app was launched with `--background` as a headless daemon.
    var isBackgroundMode: Bool = false

    /// The maximum text width used for wrapping labels and separator constraints.
    let textWidth: CGFloat = 432

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
        ensureLaunchAgent()
        startDaemon()

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
            showUpdateAlert(json: json)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: Window Management

    /// Creates the settings window if needed, brings it to front, and starts the status polling timer.
    func showWindow() {
        if window == nil { createWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatus()
        startStatusTimer()
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        if isBackgroundMode {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Starts (or restarts) the timer that polls accessibility and LaunchAgent status every 2 seconds.
    func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    // MARK: Status Updates

    /// Queries launchctl to determine the current state of the LaunchAgent.
    /// - Returns: The current ``LaunchAgentStatus``.
    func detectLaunchAgentStatus() -> LaunchAgentStatus {
        if launchAgentPaused { return .paused }
        return run("/bin/launchctl", "list", label) == 0 ? .running : .notFound
    }

    /// Refreshes the accessibility and LaunchAgent status indicators in the UI.
    func updateStatus() {
        let granted = AXIsProcessTrusted()
        accessibilityDot?.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemRed).cgColor
        accessibilityLabel?.stringValue = granted ? "Accessibility: Granted" : "Accessibility: Not Granted"

        let launchAgentStatus = detectLaunchAgentStatus()
        switch launchAgentStatus {
        case .running:
            launchAgentDot?.layer?.backgroundColor = NSColor.systemGreen.cgColor
            launchAgentLabel?.stringValue = "LaunchAgent: Running"
            launchAgentDescription?.stringValue = "The background watcher is active and will automatically approve Xcode\u{2019}s MCP permission dialogs."
            pauseResumeButton?.title = "Pause"
            pauseResumeButton?.isEnabled = true
            resumeAfterRebootCheckbox?.isEnabled = true
        case .paused:
            launchAgentDot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            launchAgentLabel?.stringValue = "LaunchAgent: Paused"
            launchAgentDescription?.stringValue = "The background watcher is paused. Permission dialogs will not be approved automatically until resumed."
            pauseResumeButton?.title = "Resume"
            pauseResumeButton?.isEnabled = true
            resumeAfterRebootCheckbox?.isEnabled = true
        case .notFound:
            launchAgentDot?.layer?.backgroundColor = NSColor.systemGray.cgColor
            launchAgentLabel?.stringValue = "LaunchAgent: Not Found"
            launchAgentDescription?.stringValue = "The background watcher is not installed. Click Reinstall to set it up again."
            pauseResumeButton?.title = "Resume"
            pauseResumeButton?.isEnabled = false
            resumeAfterRebootCheckbox?.isEnabled = false
        }
    }

    // MARK: Window Creation

    /// Builds the settings window UI programmatically using stack views.
    func createWindow() {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Xcode MCP Auto-Allower"
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let titleLabel = NSTextField(labelWithString: "Xcode MCP Auto-Allower")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let versionLabel = NSTextField(labelWithString: "Benno Kress \u{2022} Version \(appVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(versionLabel)

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 16
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(titleStack)

        mainStack.addArrangedSubview(headerStack)

        // Description
        let descriptionLabel = NSTextField(wrappingLabelWithString:
            "This app automatically approves Xcode\u{2019}s MCP permission dialogs " +
            "when AI coding assistants connect, so you don\u{2019}t have to " +
            "click \u{201C}Allow\u{201D} every single time.")
        descriptionLabel.font = NSFont.systemFont(ofSize: 13)
        descriptionLabel.preferredMaxLayoutWidth = textWidth
        mainStack.addArrangedSubview(descriptionLabel)

        // Accessibility status
        let accessibilityStatusDot = NSView()
        accessibilityStatusDot.wantsLayer = true
        accessibilityStatusDot.layer?.cornerRadius = 5
        accessibilityStatusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        accessibilityStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accessibilityStatusDot.widthAnchor.constraint(equalToConstant: 10),
            accessibilityStatusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        self.accessibilityDot = accessibilityStatusDot

        let accessibilityStatusLabel = NSTextField(labelWithString: "Accessibility: Checking\u{2026}")
        accessibilityStatusLabel.font = NSFont.systemFont(ofSize: 13)
        self.accessibilityLabel = accessibilityStatusLabel

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.addArrangedSubview(accessibilityStatusDot)
        statusRow.addArrangedSubview(accessibilityStatusLabel)
        mainStack.addArrangedSubview(statusRow)

        let accessibilityExplainer = NSTextField(wrappingLabelWithString:
            "This app needs Accessibility access in System Settings to detect and " +
            "click Xcode\u{2019}s permission dialogs automatically. If the status " +
            "above shows \u{201C}Not Granted\u{201D}, click the button below.")
        accessibilityExplainer.font = NSFont.systemFont(ofSize: 12)
        accessibilityExplainer.textColor = .secondaryLabelColor
        accessibilityExplainer.preferredMaxLayoutWidth = textWidth
        mainStack.addArrangedSubview(accessibilityExplainer)

        let openSettingsButton = NSButton(title: "Open Accessibility Settings",
                                          target: self, action: #selector(openAccessibilitySettings))
        openSettingsButton.bezelStyle = .rounded
        mainStack.addArrangedSubview(openSettingsButton)
        mainStack.addArrangedSubview(makeSeparator())

        // LaunchAgent status
        let launchAgentStatusDot = NSView()
        launchAgentStatusDot.wantsLayer = true
        launchAgentStatusDot.layer?.cornerRadius = 5
        launchAgentStatusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        launchAgentStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            launchAgentStatusDot.widthAnchor.constraint(equalToConstant: 10),
            launchAgentStatusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        self.launchAgentDot = launchAgentStatusDot

        let launchAgentStatusLabel = NSTextField(labelWithString: "LaunchAgent: Checking\u{2026}")
        launchAgentStatusLabel.font = NSFont.systemFont(ofSize: 13)
        self.launchAgentLabel = launchAgentStatusLabel

        let launchAgentStatusRow = NSStackView()
        launchAgentStatusRow.orientation = .horizontal
        launchAgentStatusRow.alignment = .centerY
        launchAgentStatusRow.spacing = 8
        launchAgentStatusRow.addArrangedSubview(launchAgentStatusDot)
        launchAgentStatusRow.addArrangedSubview(launchAgentStatusLabel)
        mainStack.addArrangedSubview(launchAgentStatusRow)

        let launchAgentDescriptionLabel = NSTextField(wrappingLabelWithString: "Checking LaunchAgent status\u{2026}")
        launchAgentDescriptionLabel.font = NSFont.systemFont(ofSize: 12)
        launchAgentDescriptionLabel.textColor = .secondaryLabelColor
        launchAgentDescriptionLabel.preferredMaxLayoutWidth = textWidth
        self.launchAgentDescription = launchAgentDescriptionLabel
        mainStack.addArrangedSubview(launchAgentDescriptionLabel)

        // Management buttons
        let pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePauseResume))
        pauseButton.bezelStyle = .rounded
        self.pauseResumeButton = pauseButton

        let reinstallButton = NSButton(title: "Reinstall LaunchAgent", target: self, action: #selector(reinstallLaunchAgent))
        reinstallButton.bezelStyle = .rounded

        let manageSpacer = NSView()
        manageSpacer.translatesAutoresizingMaskIntoConstraints = false
        manageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let uninstallButton = NSButton(title: "Uninstall", target: self, action: #selector(uninstall))
        uninstallButton.bezelStyle = .rounded
        uninstallButton.contentTintColor = .systemRed

        let manageRow = NSStackView()
        manageRow.orientation = .horizontal
        manageRow.spacing = 8
        manageRow.alignment = .centerY
        manageRow.addArrangedSubview(pauseButton)
        manageRow.addArrangedSubview(reinstallButton)
        manageRow.addArrangedSubview(manageSpacer)
        manageRow.addArrangedSubview(uninstallButton)
        manageRow.translatesAutoresizingMaskIntoConstraints = false
        manageRow.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        mainStack.addArrangedSubview(manageRow)

        let rebootCheckbox = NSButton(checkboxWithTitle: "Resume after system reboot",
                                      target: self, action: #selector(rebootCheckboxChanged(_:)))
        rebootCheckbox.state = resumeAfterReboot ? .on : .off
        self.resumeAfterRebootCheckbox = rebootCheckbox
        mainStack.addArrangedSubview(rebootCheckbox)
        mainStack.addArrangedSubview(makeSeparator())

        // Update section
        let updateButton = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdatesButtonClicked))
        updateButton.bezelStyle = .rounded

        let betaCheckbox = NSButton(checkboxWithTitle: "Include beta versions",
                                    target: self, action: #selector(betaToggleChanged(_:)))
        betaCheckbox.state = includeBetaUpdates ? .on : .off

        let updateRow = NSStackView()
        updateRow.orientation = .horizontal
        updateRow.spacing = 12
        updateRow.alignment = .centerY
        updateRow.addArrangedSubview(updateButton)
        updateRow.addArrangedSubview(betaCheckbox)
        mainStack.addArrangedSubview(updateRow)
        mainStack.addArrangedSubview(makeSeparator())

        // Footer link
        let githubLinkButton = NSButton(title: "bennokress/xcode-mcp-auto-allower on GitHub",
                                         target: self, action: #selector(openGitHub))
        githubLinkButton.isBordered = false
        githubLinkButton.font = NSFont.systemFont(ofSize: 11)
        githubLinkButton.contentTintColor = .linkColor
        if let githubImage = NSImage(named: "github.fill") {
            githubImage.isTemplate = true
            githubLinkButton.image = githubImage
            githubLinkButton.imagePosition = .imageLeading
        }
        mainStack.addArrangedSubview(githubLinkButton)

        // Layout
        guard let contentView = newWindow.contentView else { return }

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: 480),
        ])

        contentView.layoutSubtreeIfNeeded()
        newWindow.setContentSize(contentView.fittingSize)
        newWindow.center()

        self.window = newWindow
    }

    /// Creates a horizontal separator line constrained to ``textWidth``.
    /// - Returns: A configured separator box.
    func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return separator
    }

    // MARK: Actions

    /// Opens the macOS Accessibility privacy settings in System Settings.
    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Opens the project's GitHub repository in the default browser.
    @objc func openGitHub() {
        NSWorkspace.shared.open(URL(string: githubURL)!)
    }

    /// Handles the "Include beta versions" checkbox toggle and triggers a silent update check.
    @objc func betaToggleChanged(_ sender: NSButton) {
        includeBetaUpdates = sender.state == .on
        checkForUpdates(silent: true)
    }

    /// Toggles the daemon between paused and running states.
    ///
    /// When pausing, boots out the LaunchAgent and optionally removes the plist
    /// (depending on ``resumeAfterReboot``). When resuming, reinstalls via ``ensureLaunchAgent()``.
    @objc func togglePauseResume() {
        let status = detectLaunchAgentStatus()
        if status == .running {
            // Pause
            run("/bin/launchctl", "bootout", "gui/\(getuid())/\(label)")
            launchAgentPaused = true

            if !resumeAfterReboot {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath())
            }
        } else {
            // Resume
            ensureLaunchAgent()
            launchAgentPaused = false
        }
        updateStatus()
    }

    /// Handles the "Resume after system reboot" checkbox.
    ///
    /// When paused, writes or removes the plist so `launchctl` knows whether to restart after reboot.
    @objc func rebootCheckboxChanged(_ sender: NSButton) {
        resumeAfterReboot = sender.state == .on

        if launchAgentPaused {
            if resumeAfterReboot {
                writeLaunchAgentPlist()
            } else {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath())
            }
        }
    }

    /// Prompts for confirmation, then force-reinstalls the LaunchAgent from scratch.
    @objc func reinstallLaunchAgent() {
        let alert = NSAlert()
        alert.messageText = "Reinstall LaunchAgent?"
        alert.informativeText = "Use this if the background watcher isn\u{2019}t running correctly."
        alert.addButton(withTitle: "Reinstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Force reinstall by removing existing plist first
        let plistPath = launchAgentPlistPath()
        try? FileManager.default.removeItem(atPath: plistPath)
        ensureLaunchAgent()
        launchAgentPaused = false
        updateStatus()
        showInfo("Background watcher reinstalled successfully.")
    }

    /// Completely removes the app, LaunchAgent, logs, config, and Accessibility permissions.
    ///
    /// After confirmation, spawns a detached shell script that waits for this process to exit
    /// before deleting the `.app` bundle, then terminates the app.
    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Xcode MCP Auto-Allower?"
        alert.informativeText = "This will remove the app and all related data from your Mac."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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

        // 5. Reset Accessibility permission
        run("/usr/bin/tccutil", "reset", "Accessibility", label)

        // 6. Spawn detached script to delete the .app bundle after this process exits, then quit
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

    @objc func checkForUpdatesButtonClicked() {
        checkForUpdates(silent: false)
    }

    /// Fetches the latest releases from GitHub and shows an update alert if a newer version exists.
    /// - Parameter silent: When `true`, suppresses "up to date" and error messages.
    func checkForUpdates(silent: Bool = false) {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases")!
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if error != nil {
                    if !silent { self.showError("Unable to check for updates. Please check your internet connection.") }
                    return
                }

                guard let data,
                      let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    if !silent { self.showError("Unable to check for updates. Please try again later.") }
                    return
                }

                guard let json = self.firstMatchingRelease(from: releases) else {
                    if !silent { self.showInfo("You\u{2019}re on the latest version (\(appVersion)).") }
                    return
                }

                let latest = releaseVersion(from: json)

                if isNewerVersion(latest, than: appVersion) {
                    self.showUpdateAlert(json: json)
                } else {
                    if !silent { self.showInfo("You\u{2019}re on the latest version (\(appVersion)).") }
                }
            }
        }.resume()
    }

    /// Displays a modal alert offering to install the update described by the given release JSON.
    /// - Parameter json: A GitHub release JSON dictionary.
    func showUpdateAlert(json: [String: Any]) {
        let latest = releaseVersion(from: json)

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "A new version is available.\n\nInstalled: \(appVersion)\nAvailable: \(latest)"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            self.performUpdate(json: json)
        }
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
            showError("This update isn\u{2019}t available for download yet. Please try again later.")
            return
        }

        // Show progress
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading Update..."
        progressAlert.informativeText = "Installing \(latest) \u{2014} this may take a moment."
        progressAlert.addButton(withTitle: "Cancel")
        progressAlert.buttons.first?.isHidden = true

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        indicator.sizeToFit()
        progressAlert.accessoryView = indicator

        // Run download asynchronously
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }

            let abortUpdate = { [weak self] in
                DispatchQueue.main.async {
                    NSApp.stopModal()
                    self?.showError("The update could not be installed. Please try again later.")
                }
            }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("xcode-mcp-allower-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let dmgPath = temporaryDirectory.appendingPathComponent("update.dmg")

            // Download DMG synchronously on background thread
            var dmgData: Data?
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: downloadURL) { data, _, _ in
                dmgData = data
                semaphore.signal()
            }.resume()
            semaphore.wait()

            guard let dmgData else {
                abortUpdate()
                return
            }

            do {
                try dmgData.write(to: dmgPath)
            } catch {
                abortUpdate()
                return
            }

            // Mount the DMG
            let mountTask = Process()
            mountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            mountTask.arguments = ["attach", dmgPath.path, "-nobrowse", "-readonly", "-quiet"]
            mountTask.standardOutput = FileHandle.nullDevice
            mountTask.standardError = FileHandle.nullDevice
            try? mountTask.run()
            mountTask.waitUntilExit()

            // Find the .app in the mount point
            let volumesDirectory = "/Volumes"
            guard let volumes = try? FileManager.default.contentsOfDirectory(atPath: volumesDirectory) else {
                abortUpdate()
                return
            }

            var mountedAppPath: String?
            var mountPoint: String?
            for volume in volumes {
                let volumePath = "\(volumesDirectory)/\(volume)"
                let candidateApp = "\(volumePath)/Xcode MCP Auto-Allower.app"
                if FileManager.default.fileExists(atPath: candidateApp) {
                    mountedAppPath = candidateApp
                    mountPoint = volumePath
                    break
                }
            }

            guard let sourceApp = mountedAppPath, let mount = mountPoint else {
                abortUpdate()
                return
            }

            // Spawn detached updater script
            let currentAppPath = Bundle.main.bundlePath
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
                rm -rf \(self.shellQuote(currentAppPath))
                cp -R \(self.shellQuote(sourceApp)) \(self.shellQuote((currentAppPath as NSString).deletingLastPathComponent))/
                hdiutil detach \(self.shellQuote(mount)) -quiet 2>/dev/null || true
                rm -rf \(self.shellQuote(temporaryDirectory.path))
                sleep 0.5
                open \(self.shellQuote(currentAppPath))
                """

            DispatchQueue.main.async {
                NSApp.stopModal()

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-c", script]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                try? task.run()

                NSApp.terminate(nil)
            }
        }

        progressAlert.runModal()
    }

    // MARK: Helpers

    /// Wraps a string in single quotes with proper escaping for safe use in shell commands.
    /// - Parameter string: The string to quote.
    /// - Returns: A shell-safe single-quoted string.
    func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Displays a modal error alert with the given message.
    /// - Parameter message: The error description shown to the user.
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Displays a modal informational alert with the given message.
    /// - Parameter message: The information shown to the user.
    func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Xcode MCP Auto-Allower"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
