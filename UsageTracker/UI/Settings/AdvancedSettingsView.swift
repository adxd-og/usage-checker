import SwiftUI

/// Settings › Advanced's words and rules (`Settings-Advanced(-Light).dc.html`). The 2.x
/// captions the mockup cut to one line are kept as hover help.
enum AdvancedSettingsCopy {
    /// What the keychain button last reported: a one-word success, or the system's message.
    enum KeychainRequest: Equatable, Sendable {
        case granted
        case failed(String)
    }

    static let keychainHeader = "Claude keychain"
    static let keychainTitle = "Request keychain access now"
    static let keychainCaption = "Use it if Claude shows errors right after an install. Click Always Allow."
    static let keychainHelp = "Shows the macOS dialog for the Claude Code-credentials item immediately, skipping the hourly retry limit — use it if Claude shows errors right after an install. Click Always Allow in the dialog."
    static let keychainButton = "Request"

    static let adminHeader = "Admin API, Enterprise only"
    static let preferAdminTitle = "Prefer Admin API when available"
    static let adminKeyTitle = "API key"
    static let adminKeyLabel = "Admin API key"
    static let adminKeyPlaceholder = "sk-ant-admin01-…"
    static let adminHelp = "Only needed for Anthropic Team/Enterprise organisations. Personal Pro/Max accounts use the Claude Code OAuth token automatically."
    static let saveButton = "Save"
    static let deleteButton = "Delete"
    static let maskedPrefixLength = 14

    static let budgetHeader = "Budget and API"
    static let budgetTitle = "Weekly budget, pay-as-you-go"
    static let budgetCaption = "$0 shows dollars only, no percentage."
    static let budgetHelp = "For pay-as-you-go accounts without session limits: local CLI spend is measured against this budget — bars, thresholds and notifications work off the percentage. Set to $0 to just show the dollar figure."
    static let budgetLabel = "Weekly budget"
    static let budgetPlaceholder = "0"
    static let betaTitle = "Anthropic beta flag"
    static let betaHelp = "Only change if Anthropic ships a new value and the OAuth endpoint starts returning 401. Default: oauth-2025-04-20."
    static let betaPlaceholder = "anthropic-beta"
    /// The mockup's field widths.
    static let adminKeyWidth: CGFloat = 180
    static let budgetWidth: CGFloat = 90
    static let betaWidth: CGFloat = 170

    static let diagnosticsHeader = "Diagnostics"
    static let messagesTitle = "Agent messages"
    static let messagesHelp = "Received counts messages the helper delivered; dropped counts messages the socket could not decode. Zero received with hooks installed usually means Omelette was restarted after the last session started — the next prompt re-registers it."
    static let lastEventTitle = "Last event"
    static let permissionRequestsTitle = "Permission requests"
    static let helperTitle = "Helper"

    static let resetHeader = "Reset"
    static let replayTitle = "Replay welcome tour"
    static let replayButton = "Replay"
    static let resetTitle = "Reset all settings"
    static let resetCaption = "Providers, thresholds, quiet hours, menu bar. Your Admin API key stays."
    static let resetButton = "Reset"
    static let resetConfirmTitle = "Reset all settings?"
    static let resetConfirmButton = "Reset everything"
    static let resetConfirmMessage = "Every preference goes back to its default — providers, thresholds, quiet hours, the menu bar and the welcome tour. Your saved Admin API key is not touched."
    static let cancelButton = "Cancel"

    /// The line under the keychain row after a request: green on success, amber with the
    /// system's words on failure.
    static func keychainNote(_ request: KeychainRequest) -> SettingsCaption {
        switch request {
        case .granted: return SettingsCaption(text: "Access granted", token: .okText)
        case .failed(let message): return SettingsCaption(text: "Failed: \(message)", token: .warning)
        }
    }

    /// "Saved: sk-ant-admin01…" or "Not set": never the whole key.
    static func maskedKey(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "Not set" }
        return "Saved: \(key.prefix(maskedPrefixLength))…"
    }

    /// Delete is offered only when there is a key to delete.
    static func hasSavedKey(_ key: String?) -> Bool {
        !(key ?? "").isEmpty
    }

    /// "12 received · 0 dropped".
    static func messages(received: Int, dropped: Int) -> String {
        "\(received) received · \(dropped) dropped"
    }

    /// "4m ago", or "—" before the first event.
    static func lastEvent(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        return SettingsCopy.ago(from: date, now: now)
    }

    /// 2.x Agents › Permissions' four counters on one line.
    static func permissionRequests(pending: Int, answered: Int, expired: Int, released: Int) -> String {
        "\(pending) pending · \(answered) answered · \(expired) expired · \(released) released to terminal"
    }

    /// "omelette-hook v2".
    static func helper(version: Int) -> String {
        "\(AgentPaths.helperName) v\(version)"
    }

    /// "Socket ~/Library/Application Support/UsageTracker/agent.sock".
    static func socketCaption(path: String, home: String) -> String {
        "Socket \(SettingsCopy.tildePath(path, home: home))"
    }

    /// The socket's start error, 2.x's red "Socket status" row, as a red line.
    static func socketErrorNote(_ error: String?) -> SettingsCaption? {
        guard let text = error?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return SettingsCaption(text: text, token: .critical)
    }
}

/// Settings › Advanced: 2.x Account's keychain, Admin API and budget sections, 2.x
/// Advanced's beta flag, tour and reset, and 2.x Agents' diagnostics.
struct AdvancedSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var sessions = AgentSessionStore.shared

    @State private var keychainRequest: AdvancedSettingsCopy.KeychainRequest?
    @State private var adminKeyDraft = ""
    @State private var savedAdminKeyMasked = AdvancedSettingsCopy.maskedKey(nil)
    @State private var hasSavedAdminKey = false
    @State private var showsResetConfirmation = false
    @State private var received = 0
    @State private var dropped = 0
    @State private var permissionPending = 0
    @State private var permissionAnswered = 0
    @State private var permissionExpired = 0
    @State private var permissionReleased = 0

    var body: some View {
        SettingsPage(tab: .advanced) {
            keychain
            adminAPI
            budgetAndAPI
            diagnostics
            reset
        }
        .onAppear(perform: updateMaskedKey)
        .task { await pollDiagnostics() }
    }

    // MARK: - Sections

    private var keychain: some View {
        SettingsSection(header: AdvancedSettingsCopy.keychainHeader) {
            SettingsRow(
                title: AdvancedSettingsCopy.keychainTitle,
                caption: AdvancedSettingsCopy.keychainCaption,
                note: keychainRequest.map(AdvancedSettingsCopy.keychainNote),
                help: AdvancedSettingsCopy.keychainHelp
            ) {
                Button(AdvancedSettingsCopy.keychainButton, action: requestKeychainAccess)
                    .buttonStyle(.settings)
            }
        }
    }

    private var adminAPI: some View {
        SettingsSection(header: AdvancedSettingsCopy.adminHeader) {
            SettingsSwitchRow(title: AdvancedSettingsCopy.preferAdminTitle, isOn: $settings.preferAdminWhenAvailable)
            SettingsRow(
                title: AdvancedSettingsCopy.adminKeyTitle,
                caption: savedAdminKeyMasked,
                help: AdvancedSettingsCopy.adminHelp
            ) {
                SecureField(AdvancedSettingsCopy.adminKeyPlaceholder, text: $adminKeyDraft)
                    .modifier(SettingsFieldStyle(width: AdvancedSettingsCopy.adminKeyWidth, monospaced: true))
                    .accessibilityLabel(AdvancedSettingsCopy.adminKeyLabel)
                Button(AdvancedSettingsCopy.saveButton, action: saveAdminKey)
                    .buttonStyle(.settings)
                    .disabled(adminKeyDraft.isEmpty)
                if hasSavedAdminKey {
                    Button(action: deleteAdminKey) {
                        Text(AdvancedSettingsCopy.deleteButton)
                            .foregroundStyle(.om(SettingsRowRules.destructiveLabel))
                    }
                    .buttonStyle(.settings)
                }
            }
        }
    }

    private var budgetAndAPI: some View {
        SettingsSection(header: AdvancedSettingsCopy.budgetHeader) {
            SettingsRow(
                title: AdvancedSettingsCopy.budgetTitle,
                caption: AdvancedSettingsCopy.budgetCaption,
                help: AdvancedSettingsCopy.budgetHelp
            ) {
                TextField(
                    AdvancedSettingsCopy.budgetPlaceholder,
                    value: $settings.claudeWeeklyBudgetUSD,
                    format: .currency(code: "USD").precision(.fractionLength(0))
                )
                .multilineTextAlignment(.trailing)
                .modifier(SettingsFieldStyle(width: AdvancedSettingsCopy.budgetWidth))
                .accessibilityLabel(AdvancedSettingsCopy.budgetLabel)
                .onSubmit { AppState.shared.refreshNow() }
            }
            SettingsRow(title: AdvancedSettingsCopy.betaTitle, help: AdvancedSettingsCopy.betaHelp) {
                TextField(AdvancedSettingsCopy.betaPlaceholder, text: $settings.anthropicBetaHeader)
                    .autocorrectionDisabled()
                    .modifier(SettingsFieldStyle(width: AdvancedSettingsCopy.betaWidth, monospaced: true))
                    .accessibilityLabel(AdvancedSettingsCopy.betaTitle)
            }
        }
    }

    private var diagnostics: some View {
        SettingsSection(header: AdvancedSettingsCopy.diagnosticsHeader) {
            SettingsRow(title: AdvancedSettingsCopy.messagesTitle, help: AdvancedSettingsCopy.messagesHelp) {
                SettingsValueText(text: AdvancedSettingsCopy.messages(received: received, dropped: dropped))
            }
            SettingsRow(title: AdvancedSettingsCopy.lastEventTitle) {
                SettingsValueText(text: AdvancedSettingsCopy.lastEvent(sessions.lastEventAt, now: Date()))
            }
            SettingsRow(title: AdvancedSettingsCopy.permissionRequestsTitle) {
                SettingsValueText(text: AdvancedSettingsCopy.permissionRequests(
                    pending: permissionPending,
                    answered: permissionAnswered,
                    expired: permissionExpired,
                    released: permissionReleased
                ))
            }
            SettingsRow(
                title: AdvancedSettingsCopy.helperTitle,
                caption: AdvancedSettingsCopy.socketCaption(
                    path: AgentPaths.socketURL.path, home: FileManager.default.homeDirectoryForCurrentUser.path
                ),
                note: AdvancedSettingsCopy.socketErrorNote(AgentChannel.shared.startError)
            ) {
                SettingsValueText(text: AdvancedSettingsCopy.helper(version: AgentPaths.helperVersion))
            }
        }
    }

    private var reset: some View {
        SettingsSection(header: AdvancedSettingsCopy.resetHeader) {
            SettingsRow(title: AdvancedSettingsCopy.replayTitle) {
                Button(AdvancedSettingsCopy.replayButton) {
                    settings.hasSeenOnboarding = false
                    NotificationCenter.default.post(name: .replayOnboarding, object: nil)
                }
                .buttonStyle(.settings)
            }
            SettingsRow(title: AdvancedSettingsCopy.resetTitle, caption: AdvancedSettingsCopy.resetCaption) {
                Button {
                    showsResetConfirmation = true
                } label: {
                    Text(AdvancedSettingsCopy.resetButton)
                        .foregroundStyle(.om(SettingsRowRules.destructiveLabel))
                }
                .buttonStyle(.settings)
                .confirmationDialog(
                    AdvancedSettingsCopy.resetConfirmTitle,
                    isPresented: $showsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(AdvancedSettingsCopy.resetConfirmButton, role: .destructive, action: resetEverything)
                    Button(AdvancedSettingsCopy.cancelButton, role: .cancel) {}
                } message: {
                    Text(AdvancedSettingsCopy.resetConfirmMessage)
                }
            }
        }
    }

    // MARK: - Actions

    private func requestKeychainAccess() {
        do {
            try ClaudeOAuthProvider.forceKeychainRead()
            keychainRequest = .granted
            AppState.shared.refreshNow()
            // Confirmation, not a progress claim: clear it after a beat.
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                keychainRequest = nil
            }
        } catch {
            keychainRequest = .failed(error.localizedDescription)
        }
    }

    private func saveAdminKey() {
        guard !adminKeyDraft.isEmpty else { return }
        try? KeychainStore.saveAdminKey(adminKeyDraft)
        adminKeyDraft = ""
        updateMaskedKey()
        AppState.shared.refreshNow()
    }

    private func deleteAdminKey() {
        KeychainStore.deleteAdminKey()
        updateMaskedKey()
        AppState.shared.refreshNow()
    }

    /// The key itself is never kept in the view: only its mask and whether there is one.
    private func updateMaskedKey() {
        let key = KeychainStore.loadAdminKey()
        savedAdminKeyMasked = AdvancedSettingsCopy.maskedKey(key)
        hasSavedAdminKey = AdvancedSettingsCopy.hasSavedKey(key)
    }

    private func resetEverything() {
        settings.resetToDefaults()
        // Launch at login is OS state, not a stored preference, so `resetToDefaults()`
        // deliberately can't reach it. General reads it again when it next opens.
        LaunchAtLogin.isEnabled = false
        AppState.shared.restartTimer()
        AppState.shared.refreshNow()
    }

    /// The counters live on plain objects, not on an ObservableObject, so the page
    /// re-reads them while it is on screen; `.task` cancels this when it is not.
    private func pollDiagnostics() async {
        while !Task.isCancelled {
            received = AgentDiagnostics.server?.receivedCount ?? 0
            dropped = AgentDiagnostics.server?.droppedCount ?? 0
            let broker = PermissionBroker.shared
            permissionPending = broker.pending.count
            permissionAnswered = broker.answeredCount
            permissionExpired = broker.expiredCount
            permissionReleased = broker.releasedForPresenceCount
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
