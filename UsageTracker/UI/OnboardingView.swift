import SwiftUI
import UserNotifications

struct OnboardingView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var page: Int = 0
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    let onFinish: () -> Void

    private let totalPages = 3

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
                description: "We read the OAuth token that Claude Code stored in your macOS Keychain. macOS will show a one-time prompt asking you to allow this. Click **Always Allow**. Missed the dialog? Settings → Account → **Request keychain access now** shows it again."
            )

            permissionRow(
                icon: "bell.fill",
                title: "Notifications",
                description: "Alerts at 80% / 95% of any limit, plus daily summary and off-peak reminders. You can opt out in Settings."
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
