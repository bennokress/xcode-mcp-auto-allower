import ApplicationServices
import Cocoa

// MARK: - Daemon Logic

/// Maps Xcode process IDs to their corresponding accessibility observers for cleanup on termination.
var activeObservers: [pid_t: AXObserver] = [:]

/// Button labels for the "Allow" action in Xcode's MCP permission dialog.
let allowLabels: Set<String> = ["Allow"]

/// Button labels for the "Don't Allow" action in Xcode's MCP permission dialog.
let denyLabels: Set<String> = ["Don\u{2019}t Allow", "Don't Allow"]

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
        // Prompt adds the app to Accessibility settings with an off toggle so the user only needs to flip it on.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSLog("[xcode-mcp-allower] WARNING: Accessibility permission NOT granted!")
    }

    NSLog("[xcode-mcp-allower] Daemon started (v%@). Watching for Xcode MCP permission dialogs.", appVersion)
}
