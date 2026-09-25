import Foundation

/// One figure on the Agents stats row: a label over a rounded numeral.
struct AgentsStatTile: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

/// What the Agents stats row shows (liquid-glass spec § Screens, "Agents"; § Decisions,
/// "Agent time / Approval requests tiles (2026-09-25)"). 3.0 shows Sessions alone.
/// Agent time and approval requests need an on-disk agent event log and arrive in 3.1,
/// and the busiest project is removed (§ Removals). 3.1 appends its tiles here.
enum AgentsStatsRules {
    static func tiles(_ summary: AgentHistorySummary) -> [AgentsStatTile] {
        [AgentsStatTile(label: AgentsCopy.sessionsTile, value: "\(summary.sessions)")]
    }
}
