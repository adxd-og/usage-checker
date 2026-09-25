import Foundation

/// The Settings window's six tabs, in sidebar order (liquid-glass spec § Design →
/// Settings). The raw value is the title the sidebar and the page show, and the id a
/// caller parks in `SettingsRoute.pendingTab`.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case menuBar = "Menu bar"
    case providers = "Providers"
    case notifications = "Notifications"
    case integrations = "Integrations"
    case advanced = "Advanced"

    var id: String { rawValue }

    /// 2.x tabs whose rows moved (§ Removals): Agents split into Notifications and
    /// Integrations, Account into Providers and Advanced. Lowercased.
    static let retiredAgentsID = "agents"
    static let retiredAccountID = "account"

    /// The SF Symbol beside the tab's name: the mockups' glyphs (`Settings-General.dc.html`,
    /// `<nav>`): a gear, a menu bar, two stacked rows, a bell, a plug, two sliders.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .providers: return "rectangle.grid.1x2"
        case .notifications: return "bell"
        case .integrations: return "powerplug"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The tab a parked request opens (§ Packages P7): a 3.0 tab by its own name; for a
    /// 2.x id, the tab that took its main rows (Agents → Integrations, where the hooks
    /// are; Account → Providers); General for anything else. Case and surrounding space
    /// do not matter.
    static func route(legacyID: String) -> SettingsTab {
        let id = legacyID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let tab = allCases.first(where: { $0.rawValue.lowercased() == id }) {
            return tab
        }
        switch id {
        case retiredAgentsID: return .integrations
        case retiredAccountID: return .providers
        default: return .general
        }
    }

    /// The tab an arrow key moves to from `tab`: `offset` places down the sidebar,
    /// stopping at the first and the last tab as `DashboardTab.step` does.
    static func step(from tab: SettingsTab, by offset: Int) -> SettingsTab {
        let tabs = allCases
        guard let index = tabs.firstIndex(of: tab) else { return tab }
        let target = min(max(index + offset, 0), tabs.count - 1)
        return tabs[target]
    }
}
