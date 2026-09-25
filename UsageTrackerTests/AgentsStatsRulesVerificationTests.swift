import XCTest
@testable import Omelette

/// Independent verification of the session's ruling (plan
/// `docs/superpowers/plans/2026-09-25-3.0-P4-agents.md`, "Session rulings"): "stats row =
/// Sessions only (`AgentsStatsRules.tiles` returns exactly one tile)". Also checks the
/// figure against a count computed independently of `AgentHistorySummary.make`, so a bug
/// shared between the rule under test and the summary it reads would not hide here.
final class AgentsStatsRulesVerificationTests: XCTestCase {
    /// 2026-09-10 12:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_789_041_600)

    private func record(
        _ id: String,
        source: AgentSource,
        endedAt: Date,
        project: String = "Usage tracker"
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: source, project: project,
            startedAt: endedAt.addingTimeInterval(-1_800),
            endedAt: endedAt, turns: 2, needsYouCount: 0
        )
    }

    // MARK: - Exactly one tile, whatever the summary carries

    func testExactlyOneTileForAnEmptySummary() {
        let summary = AgentHistorySummary(sessions: 0, agentTime: 0, approvalsWaited: 0, busiestProject: nil)
        XCTAssertEqual(AgentsStatsRules.tiles(summary).count, 1)
    }

    func testExactlyOneTileWhenEveryOtherFieldIsAlsoPopulated() {
        // 3.1's fields still ride on the model (kept per the plan); the card must not
        // grow a second or third tile just because they are non-zero.
        let summary = AgentHistorySummary(
            sessions: 104, agentTime: 999_999, approvalsWaited: 57,
            busiestProject: (name: "Orion Gate", sessions: 40)
        )
        let tiles = AgentsStatsRules.tiles(summary)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.map(\.label), ["Sessions"])
        XCTAssertEqual(tiles[0].value, "104")
    }

    func testTheOnlyTileIsAlwaysLabelledSessions() {
        for count in [0, 1, 999] {
            let summary = AgentHistorySummary(sessions: count, agentTime: 0, approvalsWaited: 0, busiestProject: nil)
            XCTAssertEqual(AgentsStatsRules.tiles(summary).first?.label, AgentsCopy.sessionsTile)
        }
    }

    // MARK: - The figure matches an independently-filtered count

    func testTheFigureMatchesSessionsEndedInRangeFromTheChosenSourceOnly() {
        let claudeInRange = record("claude:a", source: .claude, endedAt: now.addingTimeInterval(-3_600))
        let claudeOutOfRange = record("claude:b", source: .claude, endedAt: now.addingTimeInterval(-10 * 86_400))
        let codexInRange = record("codex:a", source: .codex, endedAt: now.addingTimeInterval(-1_800))
        let records = [claudeInRange, claudeOutOfRange, codexInRange]

        let claudeSummary = AgentHistorySummary.make(records: records, source: .claude, range: .sevenDays, now: now)
        let expectedClaudeCount = records.filter {
            $0.source == .claude && $0.endedAt >= now.addingTimeInterval(-TimeRange.sevenDays.seconds)
        }.count
        XCTAssertEqual(expectedClaudeCount, 1, "sanity: only claudeInRange should qualify")
        XCTAssertEqual(AgentsStatsRules.tiles(claudeSummary).first?.value, "\(expectedClaudeCount)")

        let allSummary = AgentHistorySummary.make(records: records, source: nil, range: .sevenDays, now: now)
        let expectedAllCount = records.filter {
            $0.endedAt >= now.addingTimeInterval(-TimeRange.sevenDays.seconds)
        }.count
        XCTAssertEqual(expectedAllCount, 2, "sanity: claudeInRange and codexInRange qualify, claudeOutOfRange does not")
        XCTAssertEqual(AgentsStatsRules.tiles(allSummary).first?.value, "\(expectedAllCount)")
    }

    // MARK: - Range boundary (inclusive lower bound, per AgentHistorySummary.inRange)

    func testASessionEndingExactlyAtTheCutoffCounts() {
        let cutoff = now.addingTimeInterval(-TimeRange.oneDay.seconds)
        let summary = AgentHistorySummary.make(
            records: [record("claude:edge", source: .claude, endedAt: cutoff)],
            source: nil, range: .oneDay, now: now
        )
        XCTAssertEqual(AgentsStatsRules.tiles(summary).first?.value, "1")
    }

    func testASessionEndingOneSecondBeforeTheCutoffDoesNotCount() {
        let justBefore = now.addingTimeInterval(-TimeRange.oneDay.seconds - 1)
        let summary = AgentHistorySummary.make(
            records: [record("claude:edge", source: .claude, endedAt: justBefore)],
            source: nil, range: .oneDay, now: now
        )
        XCTAssertEqual(AgentsStatsRules.tiles(summary).first?.value, "0")
    }

    // MARK: - Value formatting

    func testTheFigureIsPlainDigitsWithNoGrouping() {
        // A NumberFormatter with .decimal style would render 1234 as "1,234"; the
        // mockup's tile is a bare integer.
        let summary = AgentHistorySummary(sessions: 1_234, agentTime: 0, approvalsWaited: 0, busiestProject: nil)
        XCTAssertEqual(AgentsStatsRules.tiles(summary).first?.value, "1234")
    }

    // MARK: - cells(_:) placement, independent of AgentsStatsRulesTests' own coverage

    func testASingleTileNeverDrawsAHairline() {
        let cells = AgentsStatsRules.cells([AgentsStatTile(label: "Sessions", value: "5")])
        XCTAssertEqual(cells.count, AgentsStatsRules.columns)
        XCTAssertFalse(cells.contains { $0.leadingDivider })
    }

    func testTheEmptyColumnsCarryNoTile() {
        let cells = AgentsStatsRules.cells([AgentsStatTile(label: "Sessions", value: "5")])
        XCTAssertNil(cells[1].tile)
        XCTAssertNil(cells[2].tile)
    }
}
