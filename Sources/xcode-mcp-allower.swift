import Cocoa
import ApplicationServices

// appVersion, githubRepo, githubURL are defined in the generated Version.swift

// MARK: - Daemon Logic

let xcodeBundleID = "com.apple.dt.Xcode"
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

        let reinstallBtn = NSButton(title: "Reinstall", target: self, action: #selector(reinstall))
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

    @objc func reinstall() {
        let alert = NSAlert()
        alert.messageText = "Reinstall Xcode MCP Auto-Allower?"
        alert.informativeText = "This will recompile and reinstall the app. It restarts automatically."
        alert.addButton(withTitle: "Reinstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let repo = repoPath() else {
            showError("Could not find the source repository. Run ./install.sh manually from the cloned repo.")
            return
        }
        runDetached("cd \(shellQuote(repo)) && ./install.sh")
    }

    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Xcode MCP Auto-Allower?"
        alert.informativeText = "This will stop the daemon and remove the app, LaunchAgent, and all related files."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let repo = repoPath() else {
            showError("Could not find the source repository. Run ./uninstall.sh manually from the cloned repo.")
            return
        }
        runDetached("cd \(shellQuote(repo)) && ./uninstall.sh")
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
                        self.performUpdate()
                    }
                } else {
                    self.showInfo("You\u{2019}re up to date! Version \(appVersion) is the latest.")
                }
            }
        }.resume()
    }

    func performUpdate() {
        guard let repo = repoPath() else {
            showError("Could not find the source repository.\n\nUpdate manually:\ncd <repo> && git pull && ./install.sh")
            return
        }
        runDetached("cd \(shellQuote(repo)) && git pull && ./install.sh")
    }

    // MARK: Helpers

    func repoPath() -> String? {
        let configFile = NSHomeDirectory() + "/.config/xcode-mcp-allower/repo-path"
        guard let path = try? String(contentsOfFile: configFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              FileManager.default.fileExists(atPath: path + "/install.sh") else {
            return nil
        }
        return path
    }

    func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runDetached(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
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

