import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var page: Int
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Background polling never prompts, so the keychain dialog has to be asked for
    /// explicitly — here on first run, or from Settings later.
    @State private var keychainGranted = ClaudeCredentialsCache.load() != nil
    @State private var keychainError: String?
    @State private var agentHooks: HookInstallStatus = .notInstalled
    @State private var agentHooksError: String?
    let onFinish: () -> Void

    /// `page` is a parameter only so each page can be previewed on its own; the
    /// app always starts the tour at the beginning.
    init(page: Int = 0, onFinish: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.onFinish = onFinish
    }

    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)

            HStack(spacing: OMSpacing.s) {
                ForEach(0..<totalPages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, OMSpacing.m)
            .padding(.vertical, OMSpacing.xs)
            .liquidGlass(in: Capsule())
            .padding(.vertical, OMSpacing.s)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") {
                        withAnimation { page -= 1 }
                    }
                    .glassButtonStyle()
                } else {
                    Button("Skip") {
                        settings.hasSeenOnboarding = true
                        onFinish()
                    }
                    .glassButtonStyle()
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
        VStack(spacing: OMSpacing.xl) {
            HStack(spacing: OMSpacing.l) {
                // The real app icon (the omelette), not a drawn stand-in — it
                // tracks icon updates for free.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                // The gauge the whole product is built on, at a comfortable
                // reading — the first screen shows what it is about to do.
                OMRing(percent: 37, size: .hero)
            }
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
        VStack(alignment: .leading, spacing: OMSpacing.l) {
            Text("Two permissions")
                .font(.title2.weight(.semibold))

            card {
                permissionRow(
                    icon: "key.fill",
                    title: "Keychain access",
                    description: "We read the OAuth token that Claude Code stored in your macOS Keychain. Click **Grant access** and macOS will ask you to allow it — choose **Always Allow**. Omelette then works from its own copy and never raises that dialog on its own; Settings → Account → **Request keychain access now** brings it back if it's ever needed again."
                )

                HStack(spacing: OMSpacing.s) {
                    OMChip(
                        text: keychainGranted ? "Access granted" : "Not granted yet",
                        tint: keychainGranted ? .green : .orange
                    )
                    Spacer()
                    Button(keychainGranted ? "Re-check" : "Grant access") {
                        requestKeychainAccess()
                    }
                    .glassButtonStyle()
                }

                if let keychainError {
                    Text(keychainError)
                        .font(OMFont.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            card {
                permissionRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    description: "Alerts at 80% / 95% of any limit, plus an optional daily summary. You can opt out in Settings."
                )

                HStack(spacing: OMSpacing.s) {
                    OMChip(text: notificationStatusLabel, tint: notificationStatusColor)
                    Spacer()
                    Button(notificationButtonLabel) {
                        handleNotificationButton()
                    }
                    .glassButtonStyle()
                }
            }

            Spacer()
        }
        .task { await refreshNotificationStatus() }
    }

    /// The one card that is an offer rather than a requirement: agent status is
    /// opt-in, works on Claude Code only from here, and is fully reversible in
    /// Settings → Agents (which also handles Codex).
    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: OMSpacing.l) {
            Text("Your agents, at a glance")
                .font(.title2.weight(.semibold))

            card {
                permissionRow(
                    icon: "bolt.horizontal.circle",
                    title: "Agent status (optional)",
                    description: "Omelette can also show which Claude Code sessions are running, which one is **waiting for your approval**, and take you back to it in one click. Turning this on adds eight hooks to `~/.claude/settings.json` that call a small helper inside Omelette. They send the session id, the tool name and the folder — never your prompts or your files — and Claude Code never waits on them. Settings → Agents shows the exact JSON, adds Codex, and removes all of it again."
                )

                HStack(spacing: OMSpacing.s) {
                    // `.conflict` carries whatever reason the installer found, which
                    // can be a whole sentence; the chip keeps one line and the tooltip
                    // holds the rest.
                    OMChip(text: agentHooksLabel, tint: agentHooksColor)
                        .lineLimit(1)
                        .help(agentHooksLabel)
                    Spacer()
                    Button(agentHooksButtonLabel) {
                        enableAgentHooks()
                    }
                    .glassButtonStyle()
                    .disabled(agentHooksInstalled)
                }

                if let agentHooksError {
                    Text(agentHooksError)
                        .font(OMFont.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
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

    /// One onboarding block on the same quiet tile the rest of the app uses for
    /// content. Glass is for controls; a card that holds text is not one.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) { content() }
            .padding(OMSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OMRadius.tile, style: .continuous)
                    .fill(OMSurface.tile)
            )
    }

    private func permissionRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: OMSpacing.m) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(OMFont.title)
                Text(.init(description))
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyPage: some View {
        VStack(spacing: OMSpacing.l) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're all set!")
                .font(.title2.weight(.semibold))
            card {
                tip("Click", "menu bar icon to open the popover")
                tip("Hover", "menu bar icon for a quick summary tooltip")
                tip("From popover", "open Dashboard, Settings, or Refresh")
                tip("Updates", "install themselves — signed and notarized")
            }
            Spacer()
        }
    }

    private func tip(_ label: String, _ description: String) -> some View {
        HStack(spacing: OMSpacing.s) {
            Text(label)
                .font(OMFont.caption.weight(.semibold))
                .padding(.horizontal, OMSpacing.s).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                .frame(minWidth: 90, alignment: .leading)
            Text(description).font(OMFont.body).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

#if DEBUG
#Preview("Tour — welcome") { OnboardingView(onFinish: {}) }
#Preview("Tour — welcome, dark") { OnboardingView(onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — permissions") { OnboardingView(page: 1, onFinish: {}) }
#Preview("Tour — permissions, dark") { OnboardingView(page: 1, onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — agents") { OnboardingView(page: 2, onFinish: {}) }
#Preview("Tour — agents, dark") { OnboardingView(page: 2, onFinish: {}).preferredColorScheme(.dark) }
#Preview("Tour — ready") { OnboardingView(page: 3, onFinish: {}) }
#Preview("Tour — ready, dark") { OnboardingView(page: 3, onFinish: {}).preferredColorScheme(.dark) }
#endif
