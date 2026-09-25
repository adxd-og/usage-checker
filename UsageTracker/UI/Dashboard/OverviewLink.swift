import Foundation

/// A summary's way to the screen that owns its detail (liquid-glass spec § Design,
/// Principle 4; § Components, "Links"). Following one is a write to the dashboard's tab
/// key (`DashboardTab.storageKey`), after History's view and chart keys where the link
/// names them; the window follows.
enum OverviewLink: Equatable, CaseIterable {
    /// "History ›": on the CLI card; for a provider with no cost log, on its first card.
    case history
    /// "Tokens by day ›": History on its Chart view, tokens chart.
    case tokensByDay

    /// The key `SessionHistoryView` keeps its chart mode under (`@AppStorage`).
    static let historyChartModeKey = "historyChartMode"

    var title: String {
        switch self {
        case .history: return "History"
        case .tokensByDay: return "Tokens by day"
        }
    }

    /// Both lead to History.
    var tab: DashboardTab { .history }

    /// The chart History opens on; nil keeps the one the user left it on.
    var chartMode: HistoryChartMode? {
        switch self {
        case .history: return nil
        case .tokensByDay: return .tokens
        }
    }

    /// The view History opens on (`HistoryRules.viewModeKey`); nil keeps the one the user
    /// left it on. The tokens chart lives on Chart, so a History left on Calendar would
    /// otherwise swallow "Tokens by day".
    var viewMode: HistoryViewMode? {
        switch self {
        case .history: return nil
        case .tokensByDay: return .chart
        }
    }

    /// The first card carries History's link only when there is no CLI card to carry it: a
    /// provider with no local cost log (Antigravity). Whichever card comes first
    /// carries it, the rings or the burn-rate card that stands in for them when the
    /// provider has no current window (signed out, its readings only in History).
    static func onFirstCard(hasBreakdown: Bool) -> OverviewLink? {
        hasBreakdown ? nil : .history
    }
}
