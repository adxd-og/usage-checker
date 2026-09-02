import XCTest
@testable import Omelette

/// The strings on the Agents tab's history rows. `View` statics are `nonisolated`
/// so the test can call them without hopping to the main actor.
final class OMAgentHistoryRowTests: XCTestCase {
    private func record(turns: Int = 4, needsYouCount: Int = 0) -> AgentSessionRecord {
        AgentSessionRecord(
            id: "claude:s1", source: .claude, project: "Usage tracker",
            startedAt: Date(timeIntervalSince1970: 1_788_329_880),
            endedAt: Date(timeIntervalSince1970: 1_788_341_400),
            turns: turns, needsYouCount: needsYouCount
        )
    }

    func testTurnsArePluralised() {
        XCTAssertEqual(OMAgentHistoryRow.turnsText(0), "0 turns")
        XCTAssertEqual(OMAgentHistoryRow.turnsText(1), "1 turn")
        XCTAssertEqual(OMAgentHistoryRow.turnsText(9), "9 turns")
    }

    func testApprovalsOnlyShowWhenThereWereAny() {
        XCTAssertNil(OMAgentHistoryRow.approvalsText(0))
        XCTAssertEqual(OMAgentHistoryRow.approvalsText(1), "⚠︎ 1")
        XCTAssertEqual(OMAgentHistoryRow.approvalsText(3), "⚠︎ 3")
    }

    func testTheSpokenLabelCarriesEverythingTheRowShows() {
        let label = OMAgentHistoryRow.accessibilityLabel(for: record(needsYouCount: 2), startedAt: "09:18")
        XCTAssertEqual(
            label,
            "Usage tracker, Claude Code, started 09:18, ran 3h 12m, 4 turns, 2 approvals waited"
        )
    }

    func testASessionWithNoApprovalsSaysNothingAboutThem() {
        let label = OMAgentHistoryRow.accessibilityLabel(for: record(turns: 1), startedAt: "09:18")
        XCTAssertEqual(label, "Usage tracker, Claude Code, started 09:18, ran 3h 12m, 1 turn")
    }
}

/// The persisted source filter. The stored value is a raw string, so it has to
/// survive a value written by a future build (or a hand-edited defaults plist).
final class AgentsHistorySourceTests: XCTestCase {
    func testAllMeansNoFilter() {
        XCTAssertNil(AgentsHistoryView.selectedSource("all"))
    }

    func testAProviderIdSelectsThatSource() {
        XCTAssertEqual(AgentsHistoryView.selectedSource("claude"), .claude)
        XCTAssertEqual(AgentsHistoryView.selectedSource("codex"), .codex)
    }

    func testAnUnknownStoredValueFallsBackToAll() {
        XCTAssertNil(AgentsHistoryView.selectedSource("antigravity"))
        XCTAssertNil(AgentsHistoryView.selectedSource(""))
    }

    func testTheStoredKeyIsTheOneTheSpecFixed() {
        XCTAssertEqual(AgentsHistoryView.sourceKey, "agentsHistorySource")
    }
}

/// What makes the Agents tab reload its history. The live session count alone misses
/// every same-count transition — a session ending as another starts, or a session
/// being archived and immediately revived by `claude --resume`.
final class AgentsHistoryReloadKeyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_788_350_400)

    func testAnEventWithNoChangeInCountStillReloads() {
        XCTAssertNotEqual(
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at),
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at.addingTimeInterval(1))
        )
    }

    func testANewSessionReloadsBeforeAnyEventHasLanded() {
        XCTAssertNotEqual(
            AgentsHistoryView.historyReloadKey(sessions: 0, lastEventAt: nil),
            AgentsHistoryView.historyReloadKey(sessions: 1, lastEventAt: nil)
        )
    }

    func testAnUnchangedStoreDoesNotReload() {
        XCTAssertEqual(
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at),
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at)
        )
    }
}
