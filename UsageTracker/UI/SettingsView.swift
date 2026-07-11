import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject private var state = AppState.shared
    @State private var selectedTab: Tab = .general
    @State private var adminKeyDraft: String = ""
    @State private var savedAdminKeyMasked: String = ""
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case notifications = "Notifications"
        case account = "Account"
        case advanced = "Advanced"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .notifications: return "bell.badge"
            case .account: return "person.crop.circle"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    /// "1.7.0 (13)" — marketing version + build number from the bundle.
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label(Tab.general.rawValue, systemImage: Tab.general.icon) }
                .tag(Tab.general)
            notificationsTab
                .tabItem { Label(Tab.notifications.rawValue, systemImage: Tab.notifications.icon) }
                .tag(Tab.notifications)
            accountTab
                .tabItem { Label(Tab.account.rawValue, systemImage: Tab.account.icon) }
                .tag(Tab.account)
            advancedTab
                .tabItem { Label(Tab.advanced.rawValue, systemImage: Tab.advanced.icon) }
                .tag(Tab.advanced)
        }
        .frame(width: 520, height: 540)
        .onAppear(perform: updateMaskedView)
    }

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Update every", selection: $settings.refreshIntervalSeconds) {
                    ForEach(RefreshInterval.allCases) { iv in
                        Text(iv.label).tag(iv.rawValue)
                    }
                }
                Text("How often the widget polls Anthropic. Faster = closer to real-time, but risks rate limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                    }
            }

            Section("Providers") {
                Toggle("Show Codex (OpenAI) usage", isOn: $settings.codexProviderEnabled)
                    .onChange(of: settings.codexProviderEnabled) { _, _ in
                        AppState.shared.refreshNow()
                    }
                Text("Reads session and weekly limits from the local Codex CLI. Requires being signed in (`codex login`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Gemini usage", isOn: $settings.geminiProviderEnabled)
                    .onChange(of: settings.geminiProviderEnabled) { _, _ in
                        AppState.shared.refreshNow()
                    }
                Text("Reads daily model quotas using the Gemini CLI's Google sign-in. API-key and Vertex AI auth don't expose quotas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show Antigravity usage", isOn: $settings.antigravityProviderEnabled)
                    .onChange(of: settings.antigravityProviderEnabled) { _, _ in
                        AppState.shared.refreshNow()
                    }
                Text("Reads model-pool quotas from a running Antigravity app, `agy` CLI, or IDE. The Gemini-CLI replacement for personal Google accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { Updater.shared.automaticallyChecksForUpdates },
                    set: { Updater.shared.automaticallyChecksForUpdates = $0 }
                ))
                HStack {
                    Button("Check for updates now") {
                        Updater.shared.checkForUpdates()
                    }
                    .disabled(!Updater.shared.canCheckForUpdates)
                    Spacer()
                    if let date = Updater.shared.lastUpdateCheckDate {
                        Text("Last check: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Self.appVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var notificationsTab: some View {
        Form {
            Section("Threshold alerts") {
                Toggle("Notify when limits are getting close", isOn: $settings.notificationsEnabled)
                if settings.notificationsEnabled {
                    Stepper(value: $settings.threshold80, in: 50...90, step: 5) {
                        Text("First warning at ") + Text("\(settings.threshold80)%").bold()
                    }
                    Stepper(value: $settings.threshold95, in: 80...99, step: 1) {
                        Text("Final warning at ") + Text("\(settings.threshold95)%").bold()
                    }
                    Text("You'll get one macOS notification when any window crosses the threshold. Resets when it drops back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Quiet hours") {
                Toggle("Silence notifications at night", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    HStack {
                        hourPicker(label: "From", selection: $settings.quietHoursStart)
                        Spacer()
                        hourPicker(label: "To", selection: $settings.quietHoursEnd)
                    }
                    Text("Threshold alerts, off-peak reminders and the daily summary are all suppressed during quiet hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Extra notifications") {
                Toggle("Daily summary at \(formatHour(settings.dailySummaryHour))", isOn: $settings.dailySummaryEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private func hourPicker(label: String, selection: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(0..<24, id: \.self) { h in
                    Text(formatHour(h)).tag(h)
                }
            }
            .labelsHidden()
            .frame(width: 80)
        }
    }

    private func formatHour(_ h: Int) -> String {
        String(format: "%02d:00", h)
    }

    private var accountTab: some View {
        Form {
            Section("Connected services") {
                let snap = state.snapshot
                if snap.services.isEmpty {
                    Text("Loading…").foregroundStyle(.secondary)
                } else {
                    ForEach(snap.services) { svc in
                        HStack(spacing: 8) {
                            Image(systemName: svc.icon).foregroundStyle(.tint).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(svc.displayName).font(.system(size: 12, weight: .medium))
                                Text(stateLabel(svc.state) + (svc.plan.map { " · \($0)" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(svc.buckets.count) buckets")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Last fetch", value: lastFetchText(snap.fetchedAt))
                if let err = snap.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Toggle("Prefer Admin API source when available", isOn: $settings.preferAdminWhenAvailable)
                SecureField("sk-ant-admin01-…", text: $adminKeyDraft)
                HStack {
                    Button("Save key") {
                        guard !adminKeyDraft.isEmpty else { return }
                        try? KeychainStore.saveAdminKey(adminKeyDraft)
                        adminKeyDraft = ""
                        updateMaskedView()
                        AppState.shared.refreshNow()
                    }
                    .disabled(adminKeyDraft.isEmpty)
                    Button("Delete key", role: .destructive) {
                        KeychainStore.deleteAdminKey()
                        updateMaskedView()
                        AppState.shared.refreshNow()
                    }
                    Spacer()
                    Text(savedAdminKeyMasked)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Only needed for Anthropic Team/Enterprise organisations. Personal Pro/Max accounts use the Claude Code OAuth token automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Admin API (Enterprise)")
            }

            Section {
                HStack {
                    Text("Weekly budget")
                    Spacer()
                    TextField("0", value: $settings.claudeWeeklyBudgetUSD, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { AppState.shared.refreshNow() }
                }
                Text("For pay-as-you-go accounts without session limits: local CLI spend is measured against this budget — bars, thresholds and notifications work off the percentage. Set to $0 to just show the dollar figure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pay-as-you-go budget")
            }
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Section("Anthropic beta flag") {
                TextField("anthropic-beta", text: $settings.anthropicBetaHeader)
                    .font(.system(.body, design: .monospaced))
                    .disableAutocorrection(true)
                Text("Only change if Anthropic ships a new value and the OAuth endpoint starts returning 401. Default: oauth-2025-04-20.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Onboarding") {
                Button("Replay welcome tour") {
                    settings.hasSeenOnboarding = false
                    NotificationCenter.default.post(name: .replayOnboarding, object: nil)
                }
            }

            Section {
                Button("Force refresh now") {
                    AppState.shared.refreshNow()
                }
                Button("Reset all settings") {
                    settings.refreshIntervalSeconds = 60
                    settings.notificationsEnabled = true
                    settings.threshold80 = 80
                    settings.threshold95 = 95
                    settings.preferAdminWhenAvailable = false
                    settings.anthropicBetaHeader = "oauth-2025-04-20"
                    settings.quietHoursEnabled = true
                    settings.quietHoursStart = 23
                    settings.quietHoursEnd = 9
                    settings.dailySummaryEnabled = true
                    settings.dailySummaryHour = 9
                }
                Button("Quit Omelette", role: .destructive) {
                    NSApp.terminate(nil)
                }
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
    }

    private func stateLabel(_ s: ServiceState) -> String {
        switch s {
        case .ok: return "Connected"
        case .notSignedIn: return "Sign in needed"
        case .notRunning: return "Not running"
        case .error: return "Error"
        }
    }

    private func lastFetchText(_ date: Date) -> String {
        if date.timeIntervalSince1970 == 0 { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func updateMaskedView() {
        if let key = KeychainStore.loadAdminKey(), !key.isEmpty {
            let prefix = String(key.prefix(14))
            savedAdminKeyMasked = "Saved: \(prefix)…"
        } else {
            savedAdminKeyMasked = "Not set"
        }
    }
}

extension Notification.Name {
    static let replayOnboarding = Notification.Name("com.usagetracker.replayOnboarding")
}
