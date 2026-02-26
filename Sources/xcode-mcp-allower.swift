import Cocoa
import ApplicationServices

// appVersion, githubRepo, githubURL are defined in the generated Version.swift

// MARK: - Constants

let label = "com.local.xcode-mcp-allower"
let xcodeBundleID = "com.apple.dt.Xcode"
let logFile = NSHomeDirectory() + "/Library/Logs/xcode-mcp-allower.log"

// MARK: - Daemon Logic

var activeObservers: [pid_t: AXObserver] = [:]

/// Permission dialog button labels by language
let allowLabels: Set<String> = ["Allow", "Erlauben"]
let denyLabels: Set<String> = ["Don\u{2019}t Allow", "Don't Allow", "Nicht erlauben"]

func clickAllowIfPresent(in app: AXUIElement) {
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
                var valRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef)
                bodyText += (valRef as? String ?? "") + " "
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
    guard AXObserverCreate(pid, callback, &observer) == .success, let obs = observer else {
        NSLog("[xcode-mcp-allower] Failed to create AXObserver for Xcode (pid %d).", pid)
        return
    }

    AXObserverAddNotification(obs, appElement, kAXWindowCreatedNotification as CFString, nil)
    AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, nil)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    activeObservers[pid] = obs

    clickAllowIfPresent(in: appElement)
    NSLog("[xcode-mcp-allower] Now observing Xcode (pid %d).", pid)
}

func teardownObserver(for pid: pid_t) {
    if let obs = activeObservers.removeValue(forKey: pid) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        NSLog("[xcode-mcp-allower] Stopped observing Xcode (pid %d).", pid)
    }
}

func startDaemon() {
    let workspace = NSWorkspace.shared
    let nc = workspace.notificationCenter

    nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == xcodeBundleID else { return }
        NSLog("[xcode-mcp-allower] Xcode launched (pid %d).", app.processIdentifier)
        setupObserver(for: app)
    }

    nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
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

// MARK: - Version Comparison

func isNewerVersion(_ remote: String, than local: String) -> Bool {
    let r = remote.split(separator: ".").compactMap { Int($0) }
    let l = local.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(r.count, l.count) {
        let rv = i < r.count ? r[i] : 0
        let lv = i < l.count ? l[i] : 0
        if rv != lv { return rv > lv }
    }
    return false
}

// MARK: - LaunchAgent Management

func launchAgentPlistPath() -> String {
    NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
}

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

    // Ensure directory exists
    let dir = (plistPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Write new plist
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

    // Reload: bootout old (if any), then bootstrap new
    let uid = getuid()
    let task1 = Process()
    task1.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task1.arguments = ["bootout", "gui/\(uid)/\(label)"]
    task1.standardOutput = FileHandle.nullDevice
    task1.standardError = FileHandle.nullDevice
    try? task1.run()
    task1.waitUntilExit()

    let task2 = Process()
    task2.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task2.arguments = ["bootstrap", "gui/\(uid)", plistPath]
    task2.standardOutput = FileHandle.nullDevice
    task2.standardError = FileHandle.nullDevice
    try? task2.run()
    task2.waitUntilExit()

    NSLog("[xcode-mcp-allower] LaunchAgent installed and loaded.")
}

// MARK: - App Delegate

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var accessibilityDot: NSView?
    var accessibilityLabel: NSTextField?
    var statusTimer: Timer?
    let textWidth: CGFloat = 432

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureLaunchAgent()
        startDaemon()
        if !CommandLine.arguments.contains("--background") {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

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
    }

    func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func updateStatus() {
        let granted = AXIsProcessTrusted()
        accessibilityDot?.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemRed).cgColor
        accessibilityLabel?.stringValue = granted ? "Accessibility: Granted" : "Accessibility: Not Granted"
    }

    // MARK: Window Creation

    func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Xcode MCP Auto-Allower"
        w.isReleasedWhenClosed = false
        w.delegate = self

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

        let versionLabel = NSTextField(labelWithString: "Version \(appVersion)")
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
        mainStack.addArrangedSubview(makeSeparator())

        // Description
        let descLabel = NSTextField(wrappingLabelWithString:
            "This app automatically approves Xcode\u{2019}s MCP permission dialogs " +
            "when AI coding assistants connect \u{2014} so you don\u{2019}t have to " +
            "click \u{201C}Allow\u{201D} every single time.")
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.preferredMaxLayoutWidth = textWidth
        mainStack.addArrangedSubview(descLabel)
        mainStack.addArrangedSubview(makeSeparator())

        // Accessibility status
        let axDot = NSView()
        axDot.wantsLayer = true
        axDot.layer?.cornerRadius = 5
        axDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        axDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            axDot.widthAnchor.constraint(equalToConstant: 10),
            axDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        self.accessibilityDot = axDot

        let axLabel = NSTextField(labelWithString: "Accessibility: Checking\u{2026}")
        axLabel.font = NSFont.systemFont(ofSize: 13)
        self.accessibilityLabel = axLabel

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.addArrangedSubview(axDot)
        statusRow.addArrangedSubview(axLabel)
        mainStack.addArrangedSubview(statusRow)

        let axExplainer = NSTextField(wrappingLabelWithString:
            "This app needs Accessibility access in System Settings to detect and " +
            "click Xcode\u{2019}s permission dialogs automatically. If the status " +
            "above shows \u{201C}Not Granted\u{201D}, click the button below.")
        axExplainer.font = NSFont.systemFont(ofSize: 12)
        axExplainer.textColor = .secondaryLabelColor
        axExplainer.preferredMaxLayoutWidth = textWidth
        mainStack.addArrangedSubview(axExplainer)

        let openSettingsBtn = NSButton(title: "Open Accessibility Settings",
                                       target: self, action: #selector(openAccessibilitySettings))
        openSettingsBtn.bezelStyle = .rounded
        mainStack.addArrangedSubview(openSettingsBtn)
        mainStack.addArrangedSubview(makeSeparator())

        // Actions
        let updateBtn = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateBtn.bezelStyle = .rounded

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let reinstallBtn = NSButton(title: "Reinstall LaunchAgent", target: self, action: #selector(reinstallLaunchAgent))
        reinstallBtn.bezelStyle = .rounded

        let uninstallBtn = NSButton(title: "Uninstall", target: self, action: #selector(uninstall))
        uninstallBtn.bezelStyle = .rounded
        uninstallBtn.contentTintColor = .systemRed

        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        actionsRow.alignment = .centerY
        actionsRow.addArrangedSubview(updateBtn)
        actionsRow.addArrangedSubview(spacer)
        actionsRow.addArrangedSubview(reinstallBtn)
        actionsRow.addArrangedSubview(uninstallBtn)
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        actionsRow.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        mainStack.addArrangedSubview(actionsRow)
        mainStack.addArrangedSubview(makeSeparator())

        // Footer link
        let linkBtn = NSButton(title: githubURL, target: self, action: #selector(openGitHub))
        linkBtn.isBordered = false
        linkBtn.font = NSFont.systemFont(ofSize: 11)
        linkBtn.contentTintColor = .linkColor
        mainStack.addArrangedSubview(linkBtn)

        // Layout
        w.contentView!.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: 480),
        ])

        w.contentView!.layoutSubtreeIfNeeded()
        w.setContentSize(w.contentView!.fittingSize)
        w.center()

        self.window = w
    }

    func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return sep
    }

    // MARK: Actions

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openGitHub() {
        NSWorkspace.shared.open(URL(string: githubURL)!)
    }

    @objc func reinstallLaunchAgent() {
        let alert = NSAlert()
        alert.messageText = "Reinstall LaunchAgent?"
        alert.informativeText = "This will rewrite and reload the LaunchAgent plist. Use this if the daemon isn\u{2019}t starting correctly."
        alert.addButton(withTitle: "Reinstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Force reinstall by removing existing plist first
        let plistPath = launchAgentPlistPath()
        try? FileManager.default.removeItem(atPath: plistPath)
        ensureLaunchAgent()
        showInfo("LaunchAgent reinstalled and loaded.")
    }

    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Xcode MCP Auto-Allower?"
        alert.informativeText = "This will stop the daemon and remove the app, LaunchAgent, and all related files."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let uid = getuid()
        let plistPath = launchAgentPlistPath()
        let configDir = NSHomeDirectory() + "/.config/xcode-mcp-allower"
        let appPath = Bundle.main.bundlePath

        // 1. Stop daemon
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(uid)/\(label)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()

        // 2. Remove LaunchAgent plist
        try? FileManager.default.removeItem(atPath: plistPath)

        // 3. Remove log file
        try? FileManager.default.removeItem(atPath: logFile)

        // 4. Remove config directory
        try? FileManager.default.removeItem(atPath: configDir)

        // 5. Reset Accessibility permission
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "Accessibility", label]
        tcc.standardOutput = FileHandle.nullDevice
        tcc.standardError = FileHandle.nullDevice
        try? tcc.run()
        tcc.waitUntilExit()

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

    @objc func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.showError("Could not check for updates:\n\(error.localizedDescription)")
                    return
                }

                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    if httpStatus == 404 {
                        self.showInfo("No releases published yet. You have the latest code.")
                    } else {
                        self.showError("Could not read update information from GitHub.")
                    }
                    return
                }

                let latest = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

                if isNewerVersion(latest, than: appVersion) {
                    let a = NSAlert()
                    a.messageText = "Update Available"
                    a.informativeText = "Version \(latest) is available (you have \(appVersion)). Update now?"
                    a.addButton(withTitle: "Update")
                    a.addButton(withTitle: "Later")
                    if a.runModal() == .alertFirstButtonReturn {
                        self.performUpdate(json: json)
                    }
                } else {
                    self.showInfo("You\u{2019}re up to date! Version \(appVersion) is the latest.")
                }
            }
        }.resume()
    }

    func performUpdate(json: [String: Any]) {
        // Find the .dmg asset URL from the release JSON
        guard let assets = json["assets"] as? [[String: Any]],
              let dmgAsset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".dmg") }),
              let downloadURLString = dmgAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            showError("No DMG found in the latest release.\n\nDownload manually from:\n\(githubURL)/releases")
            return
        }

        // Show progress
        let progressAlert = NSAlert()
        progressAlert.messageText = "Downloading Update..."
        progressAlert.informativeText = "Please wait while the update is downloaded."
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

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("xcode-mcp-allower-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dmgPath = tempDir.appendingPathComponent("update.dmg")

            // Download DMG synchronously on background thread
            guard let dmgData = try? Data(contentsOf: downloadURL) else {
                DispatchQueue.main.async {
                    NSApp.stopModal()
                    self.showError("Failed to download update.")
                }
                return
            }

            do {
                try dmgData.write(to: dmgPath)
            } catch {
                DispatchQueue.main.async {
                    NSApp.stopModal()
                    self.showError("Failed to save update: \(error.localizedDescription)")
                }
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
            // The volume name matches the app name from the DMG
            let volumesDir = "/Volumes"
            guard let volumes = try? FileManager.default.contentsOfDirectory(atPath: volumesDir) else {
                DispatchQueue.main.async {
                    NSApp.stopModal()
                    self.showError("Failed to mount update DMG.")
                }
                return
            }

            var mountedAppPath: String?
            var mountPoint: String?
            for vol in volumes {
                let volPath = "\(volumesDir)/\(vol)"
                let candidateApp = "\(volPath)/Xcode MCP Auto-Allower.app"
                if FileManager.default.fileExists(atPath: candidateApp) {
                    mountedAppPath = candidateApp
                    mountPoint = volPath
                    break
                }
            }

            guard let sourceApp = mountedAppPath, let mount = mountPoint else {
                DispatchQueue.main.async {
                    NSApp.stopModal()
                    self.showError("Could not find the app in the downloaded DMG.")
                }
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
                rm -rf \(self.shellQuote(tempDir.path))
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

    func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func showError(_ message: String) {
        let a = NSAlert()
        a.messageText = "Error"
        a.informativeText = message
        a.alertStyle = .critical
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    func showInfo(_ message: String) {
        let a = NSAlert()
        a.messageText = "Xcode MCP Auto-Allower"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
