import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Agents" ("stats row: Sessions only in 3.0") and
/// § Decisions, "Agent time / Approval requests tiles (2026-09-25)": the stats row shows
/// exactly one tile, Sessions. Busiest project is removed (§ Removals).
final class AgentsStatsRulesTests: XCTestCase {
    /// 2026-09-02 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_350_400)

    private func record(
        _ id: String,
        project: String = "Usage tracker",
        endedAt: TimeInterval,
        needsYouCount: Int = 0
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: .claude, project: project,
            startedAt: Date(timeIntervalSince1970: endedAt - 3_600),
            endedAt: Date(timeIntervalSince1970: endedAt),
            turns: 4, needsYouCount: needsYouCount
        )
    }

    func testThreePointOhShowsExactlyOneTileAndItIsSessions() {
        let summary = AgentHistorySummary.make(
            records: [
                record("claude:a", endedAt: 1_788_341_400, needsYouCount: 2), // 09:30 UTC today
                record("claude:b", project: "Jaravis", endedAt: 1_788_330_000, needsYouCount: 1),
            ],
            source: nil, range: .sevenDays, now: now
        )
        XCTAssertEqual(AgentsStatsRules.tiles(summary), [AgentsStatTile(label: "Sessions", value: "2")])
    }

    func testAgentTimeApprovalsAndTheBusiestProjectAreNotTiles() {
        // The model still carries them for 3.1 (spec § Decisions); the row does not draw them.
        let summary = AgentHistorySummary(
            sessions: 31, agentTime: 285_120, approvalsWaited: 21,
            busiestProject: (name: "Usage tracker", sessions: 12)
        )
        XCTAssertEqual(AgentsStatsRules.tiles(summary).map(\.label), ["Sessions"])
        XCTAssertEqual(AgentsStatsRules.tiles(summary).map(\.value), ["31"])
    }

    func testNothingInRangeReadsZeroSessions() {
        let summary = AgentHistorySummary.make(records: [], source: nil, range: .oneDay, now: now)
        XCTAssertEqual(AgentsStatsRules.tiles(summary).map(\.value), ["0"])
    }
}
