import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var route = SettingsRoute.shared
    @State private var selectedTab: Tab = .general
    @State private var adminKeyDraft: String = ""
    @State private var savedAdminKeyMasked: String = ""
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @State private var keychainReadStatus: String?
    @State private var showsResetConfirmation = false

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case notifications = "Notifications"
        case agents = "Agents"
        case account = "Account"
        case advanced = "Advanced"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .notifications: return "bell.badge"
            case .agents: return "bolt.horizontal.circle"
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
            AgentsSettingsView()
                .tabItem { Label(Tab.agents.rawValue, systemImage: Tab.agents.icon) }
                .tag(Tab.agents)
            accountTab
                .tabItem { Label(Tab.account.rawValue, systemImage: Tab.account.icon) }
                .tag(Tab.account)
            advancedTab
                .tabItem { Label(Tab.advanced.rawValue, systemImage: Tab.advanced.icon) }
                .tag(Tab.advanced)
        }
        .frame(width: 520, height: 540)
        .onAppear {
            updateMaskedView()
            applyPendingTab()
        }
        // The window may already be open when the popover asks for a tab, in
        // which case onAppear has long since fired.
        .onChange(of: route.pendingTab) { _, _ in applyPendingTab() }
    }

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Update every", selection: $settings.refreshIntervalSeconds) {
                    ForEach(RefreshInterval.allCases) { iv in
                        Text(iv.label).tag(iv.rawValue)
                    }
                }
                // The poll loop reads the interval only when a sleep cycle ends, so
                // without a restart a 5m → 30s change waited out the old 5 minutes.
                .onChange(of: settings.refreshIntervalSeconds) { _, _ in
                    AppState.shared.restartTimer()
                }
                Text("How often the widget polls Anthropic. Faster = closer to real-time, but risks rate limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Picker("Show the percentage", selection: $settings.menuBarNumberMode) {
                    ForEach(MenuBarNumberMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                let candidates = state.snapshot.services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }
                if candidates.isEmpty {
                    Text("Providers appear here once they report usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let shown = candidates.filter { settings.isShownInMenuBar($0.id) }
                    ForEach(candidates) { service in
                        Toggle(
                            "Show \(service.displayName)",
                            isOn: Binding(
                                get: { settings.isShownInMenuBar(service.id) },
                                set: { settings.setShownInMenuBar(service.id, $0) }
                            )
                        )
                        // Hiding the last one left the menu bar with nothing but an
                        // empty chart glyph and no way back except this screen.
                        .disabled(shown.count == 1 && shown.first?.id == service.id)
                    }
                    Text(shown.count == 1
                         ? "Hidden providers stay in the popover, the widget and notifications. The last visible one can't be hidden — the menu bar would show nothing but an empty icon."
                         : "Hidden providers stay in the popover, the widget and notifications — this only frees up menu bar width.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Peek at usage", name: .peekUsage)
                Text("Opens the popover from any app. Unset by default — click the field and press a combination.")
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
                Toggle("Show Grok usage", isOn: $settings.grokProviderEnabled)
                    .onChange(of: settings.grokProviderEnabled) { _, _ in
                        AppState.shared.refreshNow()
                    }
                Text("Reads billing-period credit usage from the local Grok CLI, with a grok.com fallback. Requires being signed in (`grok login`).")
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

            Section("Session timing") {
                Toggle("Warn when the session window is burning fast", isOn: $settings.paceAlertsEnabled)
                if settings.paceAlertsEnabled {
                    Picker("Warn this far ahead", selection: $settings.paceAlertLeadMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("45 min").tag(45)
                        Text("1 hour").tag(60)
                    }
                }
                Toggle("Tell me when the session window is about to reset", isOn: $settings.resetAlertsEnabled)
                Text("The first fires only when you'd hit the limit *before* the window resets — a pace that resets in time isn't a problem. The second fires in the last 15 minutes of a window you're already pressed against.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quiet hours") {
                Toggle("Silence notifications at night", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    HStack {
                        hourPicker(label: "From", selection: $settings.quietHoursStart)
                        Spacer()
                        hourPicker(label: "To", selection: $settings.quietHoursEnd)
                    }
                    Text("Every alert — thresholds, session timing and the daily summary — is suppressed during quiet hours.")
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
                            ProviderIconView(serviceID: svc.id, sfFallback: svc.icon, size: 14)
                                .foregroundStyle(.tint)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(svc.displayName).font(.system(size: 12, weight: .medium))
                                Text(stateLabel(svc.state) + (svc.plan.map { " · \($0)" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(usageSummary(svc))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
                HStack {
                    Button("Request keychain access now") {
                        do {
                            try ClaudeOAuthProvider.forceKeychainRead()
                            keychainReadStatus = "Access granted ✓"
                            AppState.shared.refreshNow()
                            // Confirmation, not a progress claim — clear it after a beat.
                            Task {
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                keychainReadStatus = nil
                            }
                        } catch {
                            keychainReadStatus = "Failed: \(error.localizedDescription)"
                        }
                    }
                    Spacer()
                    if let status = keychainReadStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Shows the macOS dialog for the Claude Code-credentials item immediately, skipping the hourly retry limit — use it if Claude shows errors right after an install. Click Always Allow in the dialog.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude keychain access")
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
                Button("Reset all settings", role: .destructive) {
                    showsResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all settings?",
                    isPresented: $showsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset everything", role: .destructive) {
                        settings.resetToDefaults()
                        // Launch at login is OS state, not a stored preference, so
                        // `resetToDefaults()` deliberately can't reach it — and the
                        // toggle's own `@State` has to be re-read afterwards or it goes
                        // on showing the value it had before the reset.
                        LaunchAtLogin.isEnabled = false
                        launchAtLogin = LaunchAtLogin.isEnabled
                        AppState.shared.restartTimer()
                        AppState.shared.refreshNow()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every preference goes back to its default — providers, thresholds, quiet hours, the menu bar and the welcome tour. Your saved Admin API key is not touched.")
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

    /// What this service is actually reporting, in the words the rest of the app
    /// uses — "3 buckets" was an internal count nobody outside the code reads.
    /// The two windows closest to their limit, or the pay-as-you-go spend, and a
    /// dash when the service has reported nothing (the state label above says why).
    private func usageSummary(_ svc: ServiceSnapshot) -> String {
        let worst = svc.buckets
            .filter { !$0.isPromotional }
            .sorted { $0.clampedPercent > $1.clampedPercent }
            .prefix(2)
        if !worst.isEmpty {
            return worst
                .map { "\(shortWindowName($0)) \(Int($0.clampedPercent.rounded()))%" }
                .joined(separator: " · ")
        }
        if let extra = svc.extraUsage, extra.isEnabled, extra.monthlyLimit > 0 {
            return String(format: "$%.2f of $%.2f", extra.usedCredits, extra.monthlyLimit)
        }
        if let cost = svc.weekCost, cost > 0 {
            return String(format: "$%.2f this week", cost)
        }
        return "—"
    }

    private func shortWindowName(_ b: UsageBucket) -> String {
        switch b.kind {
        case .session: return "Session"
        case .weekly: return "Week"
        case .modelSpecific, .other: return b.label
        }
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

    /// The popover can ask for a specific tab ("Enable precise status" → Agents).
    /// An unknown name is ignored, which keeps the request harmless.
    private func applyPendingTab() {
        guard let name = route.consumePendingTab(), let tab = Tab(rawValue: name) else { return }
        selectedTab = tab
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
