import Cocoa
import SwiftUI

// MARK: - Status Dot

/// A small circle used as a status indicator.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
}

// MARK: - Update Progress View

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

// MARK: - Settings View

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
