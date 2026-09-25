import SwiftUI

/// Settings › Providers' words and rules (`Settings-Providers(-Light).dc.html`): one row
/// per provider with its logo, where its numbers come from, its state as a dot and a
/// line, its switch, and "Forget last known" on a provider that is showing kept numbers.
enum ProvidersSettingsCopy {
    struct Provider: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        /// Where its numbers come from. nil for a provider the app knows only from a poll.
        let source: String?
        /// The SF Symbol when the logo asset is missing.
        let sfFallback: String
        /// Claude, and the Admin API organisation, are always polled: no switch.
        let hasSwitch: Bool
    }

    static let claudeID = "claude"
    static let codexID = "codex"
    static let antigravityID = "antigravity"
    static let grokID = "grok"
    static let adminID = "anthropic-admin"

    /// The mockup's four rows, in its order.
    static let listed: [Provider] = [
        Provider(id: claudeID, name: "Claude", source: "Claude Code sign-in", sfFallback: "sparkles", hasSwitch: false),
        Provider(id: codexID, name: "Codex", source: "Local Codex CLI, needs codex login", sfFallback: "terminal", hasSwitch: true),
        Provider(id: antigravityID, name: "Antigravity", source: "Running Antigravity app, agy CLI or IDE", sfFallback: "circle.hexagongrid", hasSwitch: true),
        Provider(id: grokID, name: "Grok", source: "Local Grok CLI, grok.com fallback", sfFallback: "bolt", hasSwitch: true),
    ]

    static let adminSource = "Admin API key, in Advanced"
    static let forgetLink = "Forget last known"
    static let forgetHelp = "Clears the stored reading for that provider. The dimmed \"last known\" numbers disappear straight away and come back only when it reports again."

    // Row metrics (`Settings-Providers.dc.html`).
    static let logoBox: CGFloat = 28
    static let logoGlyph: CGFloat = 20
    static let nameSize: CGFloat = 13.5
    static let sourceSize: CGFloat = 12
    static let nameSpacing: CGFloat = 8
    static let lineSpacing: CGFloat = 3
    static let trailingSpacing: CGFloat = 14
    static let verticalPadding: CGFloat = 12

    /// The four listed providers, then any other service the last poll returned (the
    /// Admin API organisation, which 2.x's Account tab listed too), without a switch.
    static func rows(services: [ServiceSnapshot]) -> [Provider] {
        let listedIDs = Set(listed.map(\.id))
        let others = services
            .filter { !listedIDs.contains($0.id) }
            .map { service in
                Provider(
                    id: service.id,
                    name: service.displayName,
                    source: service.id == adminID ? adminSource : nil,
                    sfFallback: service.icon,
                    hasSwitch: false
                )
            }
        return listed + others
    }

    /// VoiceOver's name for a provider's switch.
    static func switchLabel(_ name: String) -> String {
        "Show \(name)"
    }

    static func logo(for provider: Provider, service: ServiceSnapshot?) -> SettingsLogo {
        SettingsLogo(
            serviceID: provider.id,
            sfFallback: service?.icon ?? provider.sfFallback,
            boxSize: logoBox,
            glyphSize: logoGlyph
        )
    }

    /// The row's state (spec § Settings: "status is a dot + text"): "Connected · Max 20x",
    /// "Not running · last known 12:50", "Off". A switched-off provider is off whatever
    /// it last said; one switched on and not yet polled is "Checking…".
    static func status(
        for service: ServiceSnapshot?,
        isEnabled: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SettingsStatus {
        guard isEnabled else { return SettingsStatus(text: "Off", dot: .muted) }
        guard let service else { return SettingsStatus(text: "Checking…", dot: .muted) }
        let stamp = RetainedCopy.lastKnownStamp(for: service, now: now, calendar: calendar, locale: locale)
        switch service.state {
        case .ok:
            let plan = PopoverCopy.planLine(plan: service.plan, displayName: service.displayName)
            return SettingsStatus(text: ["Connected", plan].compactMap { $0 }.joined(separator: " · "), dot: .ok)
        case .notRunning:
            return SettingsStatus(text: withStamp("Not running", stamp), dot: .muted)
        case .notSignedIn:
            return SettingsStatus(text: withStamp("Sign in needed", stamp), dot: .warning)
        case .error:
            return SettingsStatus(text: withStamp("Error", stamp), dot: .critical)
        }
    }

    /// Only a provider showing kept numbers has anything visible to forget (spec: "'Forget
    /// last known' inline" on the retained row).
    static func showsForget(_ service: ServiceSnapshot?) -> Bool {
        service?.isRetained == true
    }

    /// "Last fetch 7s ago"; "Nothing fetched yet" before the first reading.
    static func lastFetch(fetchedAt: Date, now: Date) -> String {
        guard fetchedAt.timeIntervalSince1970 >= 1 else { return "Nothing fetched yet" }
        return "Last fetch \(SettingsCopy.ago(from: fetchedAt, now: now))"
    }

    /// The caption under the list.
    static func footer(fetchedAt: Date, now: Date) -> String {
        "Claude is always on. \(lastFetch(fetchedAt: fetchedAt, now: now)). A provider that is closed keeps its last known numbers, dimmed, until you forget them."
    }

    /// The last poll's error, 2.x Account's warning line, as an amber line under the list.
    static func lastErrorNote(_ error: String?) -> SettingsCaption? {
        guard let text = error?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return SettingsCaption(text: text, token: .warning)
    }

    private static func withStamp(_ state: String, _ stamp: String?) -> String {
        guard let stamp else { return state }
        return "\(state) · last known \(stamp)"
    }
}

/// Settings › Providers: 2.x Account › Connected services and General › Providers in one
/// list. The row's age is worked out when the page draws; `AppState` redraws it on every
/// poll, as 2.x's "Last fetch" row was (no timer: text built in a hidden window flips on
/// macOS 27).
struct ProvidersSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        let snapshot = state.snapshot
        let now = Date()
        SettingsPage(tab: .providers) {
            SettingsSection(
                footer: ProvidersSettingsCopy.footer(fetchedAt: snapshot.fetchedAt, now: now),
                note: ProvidersSettingsCopy.lastErrorNote(snapshot.lastError)
            ) {
                ForEach(ProvidersSettingsCopy.rows(services: snapshot.services)) { provider in
                    row(provider, service: snapshot.services.first { $0.id == provider.id }, now: now)
                }
            }
        }
        // A provider switched on or off is polled, or dropped, at once.
        .onChange(of: settings.codexProviderEnabled) { _, _ in AppState.shared.refreshNow() }
        .onChange(of: settings.antigravityProviderEnabled) { _, _ in AppState.shared.refreshNow() }
        .onChange(of: settings.grokProviderEnabled) { _, _ in AppState.shared.refreshNow() }
    }

    private func row(_ provider: ProvidersSettingsCopy.Provider, service: ServiceSnapshot?, now: Date) -> some View {
        let toggle = enabledBinding(for: provider)
        let status = ProvidersSettingsCopy.status(for: service, isEnabled: toggle?.wrappedValue ?? true, now: now)
        return HStack(spacing: SettingsRowRules.spacing) {
            SettingsLogoView(logo: ProvidersSettingsCopy.logo(for: provider, service: service))
            VStack(alignment: .leading, spacing: ProvidersSettingsCopy.lineSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: ProvidersSettingsCopy.nameSpacing) {
                    Text(provider.name)
                        .font(.system(size: ProvidersSettingsCopy.nameSize, weight: .semibold))
                        .foregroundStyle(.om(.text))
                    if let source = provider.source {
                        Text(source)
                            .font(.system(size: ProvidersSettingsCopy.sourceSize))
                            .foregroundStyle(.om(.secondary))
                            .lineLimit(1)
                    }
                }
                SettingsStatusLabel(status: status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: ProvidersSettingsCopy.trailingSpacing) {
                if ProvidersSettingsCopy.showsForget(service) {
                    Button(ProvidersSettingsCopy.forgetLink) {
                        state.forgetLastKnown(serviceID: provider.id)
                    }
                    .buttonStyle(.omLink)
                    .help(ProvidersSettingsCopy.forgetHelp)
                }
                if let toggle {
                    SettingsSwitch(label: ProvidersSettingsCopy.switchLabel(provider.name), isOn: toggle)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, SettingsRowRules.horizontalPadding)
        .padding(.vertical, ProvidersSettingsCopy.verticalPadding)
    }

    /// The provider's 2.x switch. nil for Claude and any provider without one.
    private func enabledBinding(for provider: ProvidersSettingsCopy.Provider) -> Binding<Bool>? {
        guard provider.hasSwitch else { return nil }
        switch provider.id {
        case ProvidersSettingsCopy.codexID: return $settings.codexProviderEnabled
        case ProvidersSettingsCopy.antigravityID: return $settings.antigravityProviderEnabled
        case ProvidersSettingsCopy.grokID: return $settings.grokProviderEnabled
        default: return nil
        }
    }
}
