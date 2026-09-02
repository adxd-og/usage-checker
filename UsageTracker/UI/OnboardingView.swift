import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var page: Int = 0
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Background polling never prompts, so the keychain dialog has to be asked for
    /// explicitly — here on first run, or from Settings later.
    @State private var keychainGranted = ClaudeCredentialsCache.load() != nil
    @State private var keychainError: String?
    @State private var agentHooks: HookInstallStatus = .notInstalled
    @State private var agentHooksError: String?
    let onFinish: () -> Void

    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)

            HStack(spacing: 8) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 12)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") {
                        withAnimation { page -= 1 }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Skip") {
                        settings.hasSeenOnboarding = true
                        onFinish()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if page < totalPages - 1 {
                    Button("Continue") {
                        withAnimation { page += 1 }
                    }
                    .keyboardShortcut(.return)
                    .glassProminentButtonStyle()
                } else {
                    Button("Start tracking") {
                        settings.hasSeenOnboarding = true
                        onFinish()
                    }
                    .keyboardShortcut(.return)
                    .glassProminentButtonStyle()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: welcomePage
        case 1: permissionsPage
        case 2: agentsPage
        default: readyPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            // The real app icon (the omelette), not a drawn stand-in — it
            // tracks icon updates for free.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text("Welcome to Omelette")
                .font(.title2.weight(.semibold))
            Text("A menu bar widget that watches your AI usage limits in real time — Claude, Codex, Grok, Antigravity — so you never get surprised by hitting a limit mid-task.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            Spacer()
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two permissions")
                .font(.title2.weight(.semibold))

            permissionRow(
                icon: "key.fill",
                title: "Keychain access",
                description: "We read the OAuth token that Claude Code stored in your macOS Keychain. Click **Grant access** and macOS will ask you to allow it — choose **Always Allow**. Omelette then works from its own copy and never raises that dialog on its own; Settings → Account → **Request keychain access now** brings it back if it's ever needed again."
            )

            HStack(spacing: 8) {
                Circle()
                    .fill(keychainGranted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(keychainGranted ? "Access granted" : "Not granted yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(keychainGranted ? "Re-check" : "Grant access") {
                    requestKeychainAccess()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            if let keychainError {
                Text(keychainError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            permissionRow(
                icon: "bell.fill",
                title: "Notifications",
                description: "Alerts at 80% / 95% of any limit, plus an optional daily summary. You can opt out in Settings."
            )

            HStack(spacing: 8) {
                Circle()
                    .fill(notificationStatusColor)
                    .frame(width: 8, height: 8)
                Text(notificationStatusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(notificationButtonLabel) {
                    handleNotificationButton()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Spacer()
        }
        .task { await refreshNotificationStatus() }
    }

    /// The one card that is an offer rather than a requirement: agent status is
    /// opt-in, works on Claude Code only from here, and is fully reversible in
    /// Settings → Agents (which also handles Codex).
    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your agents, at a glance")
                .font(.title2.weight(.semibold))

            permissionRow(
                icon: "bolt.horizontal.circle",
                title: "Agent status (optional)",
                description: "Omelette can also show which Claude Code sessions are running, which one is **waiting for your approval**, and take you back to it in one click. Turning this on adds eight hooks to `~/.claude/settings.json` that call a small helper inside Omelette. They send the session id, the tool name and the folder — never your prompts or your files — and Claude Code never waits on them. Settings → Agents shows the exact JSON, adds Codex, and removes all of it again."
            )

            HStack(spacing: 8) {
                Circle()
                    .fill(agentHooksColor)
                    .frame(width: 8, height: 8)
                Text(agentHooksLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(agentHooksButtonLabel) {
                    enableAgentHooks()
                }
                .buttonStyle(.bordered)
                .disabled(agentHooksInstalled)
            }
            .padding(.top, 4)

            if let agentHooksError {
                Text(agentHooksError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .onAppear(perform: refreshAgentHooks)
    }

    private var agentHooksInstalled: Bool {
        if case .installed = agentHooks { return true }
        return false
    }

    private var agentHooksLabel: String {
        switch agentHooks {
        case .installed: return "Hooks installed"
        case .outdated: return "Hooks installed — older than this build"
        case .notInstalled: return "Not enabled"
        case .conflict(let reason): return reason
        }
    }

    private var agentHooksColor: Color {
        switch agentHooks {
        case .installed: return .green
        case .outdated: return .orange
        case .notInstalled: return .secondary
        case .conflict: return .red
        }
    }

    private var agentHooksButtonLabel: String {
        switch agentHooks {
        case .installed: return "Enabled"
        case .outdated: return "Update"
        case .notInstalled, .conflict: return "Enable"
        }
    }

    private func refreshAgentHooks() {
        agentHooks = AgentHooksInstaller.claudeStatus(
            settingsURL: AgentPaths.claudeSettingsURL,
            helperPath: AgentPaths.helperSymlinkURL.path
        )
    }

    private func enableAgentHooks() {
        do {
            try AgentHooksInstaller.installClaude(
                settingsURL: AgentPaths.claudeSettingsURL,
                helperPath: AgentPaths.helperSymlinkURL.path
            )
            agentHooksError = nil
        } catch {
            agentHooksError = "Couldn't write ~/.claude/settings.json: \(error.localizedDescription)"
        }
        refreshAgentHooks()
    }

    private var notificationStatusColor: Color {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        @unknown default: return .secondary
        }
    }

    private var notificationStatusLabel: String {
        switch notificationStatus {
        case .authorized: return "Notifications: enabled"
        case .provisional: return "Notifications: provisional"
        case .ephemeral: return "Notifications: ephemeral"
        case .denied: return "Notifications: blocked"
        case .notDetermined: return "Notifications: not requested yet"
        @unknown default: return "Notifications: unknown state"
        }
    }

    private var notificationButtonLabel: String {
        switch notificationStatus {
        case .notDetermined: return "Request"
        case .denied: return "Open System Settings"
        case .authorized, .provisional, .ephemeral: return "Manage in System Settings"
        @unknown default: return "Open System Settings"
        }
    }

    private func handleNotificationButton() {
        switch notificationStatus {
        case .notDetermined:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                Task { @MainActor in await refreshNotificationStatus() }
            }
        default:
            openSystemNotificationSettings()
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notificationStatus = settings.authorizationStatus }
    }

    private func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.usagetracker.app"
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func requestKeychainAccess() {
        do {
            try ClaudeOAuthProvider.forceKeychainRead()
            keychainGranted = true
            keychainError = nil
            AppState.shared.refreshNow()
        } catch {
            keychainGranted = false
            keychainError = error.localizedDescription
        }
    }

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(.init(description))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                tip("Click", "menu bar icon to open the popover")
                tip("Hover", "menu bar icon for a quick summary tooltip")
                tip("From popover", "open Dashboard, Settings, or Refresh")
                tip("Updates", "install themselves — signed and notarized")
            }
            Spacer()
        }
    }

    private func tip(_ label: String, _ description: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                .frame(minWidth: 90, alignment: .leading)
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
