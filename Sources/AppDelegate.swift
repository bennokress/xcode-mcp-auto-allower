import Cocoa
import SwiftUI
import UserNotifications

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
        let appName = "Xcode MCP Auto-Allower.app"
        let allAppPaths = Set([
            appPath,
            home + "/Applications/" + appName,
            "/Applications/" + appName,
        ])
        let pid = ProcessInfo.processInfo.processIdentifier
        let rmLines = allAppPaths.map { "rm -rf \(shellQuote($0))" }.joined(separator: "\n")
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            \(rmLines)
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
