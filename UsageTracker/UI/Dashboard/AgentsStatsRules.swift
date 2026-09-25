import Foundation

/// One figure on the Agents stats card: a label over a rounded numeral.
struct AgentsStatTile: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

/// One column of the stats card's row: a tile or nothing, and whether a hairline runs
/// down its leading edge (the mockup's `border-left`, on every column after the first
/// that holds a tile — an empty column draws no line next to nothing).
struct AgentsStatCell: Equatable, Identifiable, Sendable {
    let column: Int
    let tile: AgentsStatTile?
    let leadingDivider: Bool
    var id: Int { column }
}

/// What the Agents stats card shows, and where (liquid-glass spec § Screens, "Agents";
/// § Decisions, "Agent time / Approval requests tiles (2026-09-25)"). The mockup's row
/// has three equal columns: Sessions, Agent time, Approval requests. The last two need
/// an on-disk agent event log and arrive in 3.1, so 3.0 fills the first column and
/// leaves the other two empty. 3.1 appends its tiles to `tiles(_:)`; `cells(_:)` and the
/// card draw them with no layout change.
enum AgentsStatsRules {
    static let columns = 3

    static func tiles(_ summary: AgentHistorySummary) -> [AgentsStatTile] {
        [AgentsStatTile(label: AgentsCopy.sessionsTile, value: "\(summary.sessions)")]
    }

    /// Exactly `columns` cells, tiles from the left.
    static func cells(_ tiles: [AgentsStatTile]) -> [AgentsStatCell] {
        (0..<columns).map { column in
            let tile = column < tiles.count ? tiles[column] : nil
            return AgentsStatCell(column: column, tile: tile, leadingDivider: column > 0 && tile != nil)
        }
    }
}
