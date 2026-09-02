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
