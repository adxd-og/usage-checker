import Foundation

/// The decisions History's page takes about its controls and its days (liquid-glass
/// spec § Screens, "History · Chart", "History · Calendar", "History · quota-only
/// provider"). Pure, nonisolated and tested; the views only draw what these say.
/// Each `extension` below is one concern.
enum HistoryRules {}

// MARK: - Cost and Tokens

extension HistoryRules {
    /// The units the chart offers. The chat list is no longer a mode: it sits under the
    /// chart in both (spec § Screens, "History · Chart").
    static let chartModes: [HistoryChartMode] = [.cost, .tokens]

    /// The unit in force for a stored value. `sessions`, 2.x's third mode, can still be
    /// in `historyChartMode`; it reads as Cost, with the chat list under the chart.
    static func effectiveMode(stored: HistoryChartMode) -> HistoryChartMode {
        chartModes.contains(stored) ? stored : .cost
    }
}
