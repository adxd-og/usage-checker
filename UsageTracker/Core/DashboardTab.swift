import Foundation

/// The dashboard's screens, in sidebar order (liquid-glass spec § Packages P2). 2.x had
/// a fifth, Activity; its heatmap folds into History in 3.0 (§ Removals), so a window
/// last left on Activity reopens on History.
enum DashboardTab: String, CaseIterable, Identifiable, Sendable {
    case overview = "Overview"
    case agents = "Agents"
    case history = "History"
    case insights = "Insights"

    var id: String { rawValue }

    /// The `UserDefaults` key the window keeps its tab under: 2.x's key, so an update
    /// opens where the user left off.
    static let storageKey = "dashboardTab"

    /// What 2.x stored while the window was on its Activity tab.
    static let retiredActivityValue = "Activity"

    /// The SF Symbol beside the tab's name in the sidebar: the mockups' glyphs
    /// (`Dashboard-Overview(-Light).dc.html`), a 2×2 grid, a person, a clock, a bulb.
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .agents: return "person"
        case .history: return "clock"
        case .insights: return "lightbulb"
        }
    }

    /// The tab a stored value opens on: its own tab; History for 2.x's Activity, where
    /// the heatmap went; Overview for anything else.
    static func route(storedValue: String) -> DashboardTab {
        if storedValue == retiredActivityValue { return .history }
        return DashboardTab(rawValue: storedValue) ?? .overview
    }
}
