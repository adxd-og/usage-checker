import SwiftUI

/// Settings › Menu bar's words and rules (`Settings-Menubar(-Light).dc.html`).
enum MenuBarSettingsCopy {
    static let numbersHeader = "Numbers"
    static let percentageTitle = "Show the percentage"
    static let countDownTitle = "Count down remaining instead of used"
    static let countDownCaption = "Everywhere: menu bar, popover, dashboard, widgets, CLI. Colours and alerts still follow what you used."
    static let providersHeader = "Providers in the menu bar"
    static let providersFooter = "Hidden providers stay in the popover, widgets and notifications. The last one can't be hidden."
    static let providersEmpty = "Providers appear here once they report usage."
    static let agentsHeader = "Agents"
    static let agentsTitle = "Show agents in the menu bar"
    /// The mockup's 20 pt logo box.
    static let logoBox: CGFloat = 20
    static let logoGlyph: CGFloat = 15

    /// VoiceOver's name for a provider's switch, 2.x's toggle title.
    static func switchLabel(_ name: String) -> String {
        "Show \(name)"
    }

    /// Providers that can take a place in the menu bar: those with a window or spend to show.
    static func candidates(_ services: [ServiceSnapshot]) -> [ServiceSnapshot] {
        services.filter { !$0.buckets.isEmpty || $0.weekCost != nil }
    }

    /// Whether `serviceID`'s switch may be turned off. Hiding the last visible provider
    /// left the menu bar with an empty glyph and no way back but this screen.
    static func canHide(_ serviceID: String, candidates: [ServiceSnapshot], hidden: Set<String>) -> Bool {
        let shown = candidates.filter { !hidden.contains($0.id) }
        return !(shown.count == 1 && shown.first?.id == serviceID)
    }

    static func logo(for service: ServiceSnapshot) -> SettingsLogo {
        SettingsLogo(serviceID: service.id, sfFallback: service.icon, boxSize: logoBox, glyphSize: logoGlyph)
    }
}

/// Settings › Menu bar: 2.x General's Menu bar and Percentages sections, and the agents
/// pill from 2.x Agents › Alerts.
struct MenuBarSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var state = AppState.shared

    var body: some View {
        SettingsPage(tab: .menuBar) {
            numbers
            providers
            agents
        }
    }

    private var numbers: some View {
        SettingsSection(header: MenuBarSettingsCopy.numbersHeader) {
            SettingsRow(title: MenuBarSettingsCopy.percentageTitle) {
                Picker(MenuBarSettingsCopy.percentageTitle, selection: $settings.menuBarNumberMode) {
                    ForEach(MenuBarNumberMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            SettingsSwitchRow(
                title: MenuBarSettingsCopy.countDownTitle,
                caption: MenuBarSettingsCopy.countDownCaption,
                isOn: $settings.showsRemaining
            )
            // The app's views repaint on their own; the widget and the omelette CLI read
            // files, which are rewritten now rather than at the next poll.
            .onChange(of: settings.showsRemaining) { _, _ in
                AppState.shared.republishDisplayMode()
            }
        }
    }

    private var providers: some View {
        let candidates = MenuBarSettingsCopy.candidates(state.snapshot.services)
        return SettingsSection(
            header: MenuBarSettingsCopy.providersHeader,
            footer: candidates.isEmpty ? nil : MenuBarSettingsCopy.providersFooter
        ) {
            if candidates.isEmpty {
                SettingsRow(title: MenuBarSettingsCopy.providersEmpty) {
                    EmptyView()
                }
            } else {
                ForEach(candidates) { service in
                    SettingsRow(title: service.displayName, logo: MenuBarSettingsCopy.logo(for: service)) {
                        SettingsSwitch(
                            label: MenuBarSettingsCopy.switchLabel(service.displayName),
                            isOn: Binding(
                                get: { settings.isShownInMenuBar(service.id) },
                                set: { settings.setShownInMenuBar(service.id, $0) }
                            )
                        )
                        .disabled(!MenuBarSettingsCopy.canHide(
                            service.id, candidates: candidates, hidden: settings.menuBarHiddenServices
                        ))
                    }
                }
            }
        }
    }

    private var agents: some View {
        SettingsSection(header: MenuBarSettingsCopy.agentsHeader) {
            SettingsSwitchRow(title: MenuBarSettingsCopy.agentsTitle, isOn: $settings.agentsShowInMenuBar)
        }
    }
}
