import XCTest
import SwiftUI
@testable import Omelette

final class AgentsSectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ name: String, _ state: AgentState, minutesAgo: Double, source: AgentSource = .claude) -> AgentSession {
        // The id is derived from source + sessionID, so `sessionID: name` is what
        // keeps these distinct.
        Fixture.agentSession(
            sessionID: name,
            source: source,
            projectName: name,
            state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    // MARK: grouped (All tab)

    func testGroupsAreOrderedByStateAndEmptyOnesAreDropped() {
        let sessions = [
            session("Jaravis", .done, minutesAgo: 5),
            session("Usage tracker", .needsYou, minutesAgo: 1),
            session("Orion Gate", .working, minutesAgo: 14),
        ]
        let groups = AgentsSection.groups(sessions)
        XCTAssertEqual(groups.map(\.state), [.needsYou, .working, .done])
        XCTAssertEqual(groups.map(\.id), ["needsYou", "working", "done"])
    }

    func testGroupMembersAreMostRecentlyActiveFirst() {
        let sessions = [session("old", .working, minutesAgo: 30), session("new", .working, minutesAgo: 2)]
        XCTAssertEqual(AgentsSection.groups(sessions).first?.sessions.map(\.projectName), ["new", "old"])
    }

    func testGroupsOfNothingIsEmpty() {
        XCTAssertTrue(AgentsSection.groups([]).isEmpty)
    }

    // MARK: flat (provider tab)

    func testFlatPutsWaitingSessionsFirstThenMostRecent() {
        let sessions = [
            session("recent", .working, minutesAgo: 1),
            session("waiting", .needsYou, minutesAgo: 20),
            session("old", .done, minutesAgo: 40),
        ]
        XCTAssertEqual(AgentsSection.flat(sessions).map(\.projectName), ["waiting", "recent", "old"])
    }

    func testSeveralWaitingSessionsKeepRecencyOrder() {
        let sessions = [session("first", .needsYou, minutesAgo: 9), session("second", .needsYou, minutesAgo: 3)]
        XCTAssertEqual(AgentsSection.flat(sessions).map(\.projectName), ["second", "first"])
    }

    // MARK: copy and styling rules

    func testSessionsCaption() {
        XCTAssertEqual(AgentsSection.sessionsCaption(0), "0 sessions")
        XCTAssertEqual(AgentsSection.sessionsCaption(1), "1 session")
        XCTAssertEqual(AgentsSection.sessionsCaption(4), "4 sessions")
    }

    func testFinishedRowsDim() {
        XCTAssertEqual(AgentsSection.rowOpacity(.needsYou), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.working), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.done), 0.7, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.idle), 0.7, accuracy: 0.001)
    }

    // MARK: two-row floor, for the popover's height budget

    /// Popover height budget spec 2026-10-27, session call Q2 and plan ruling C4: the
    /// floor is the first two rows as measured with the hairline between them, so two
    /// tall rows (a needs-you row with Allow/Deny leads the list) stay whole.
    func testTheTwoRowFloorIsTheFirstTwoRowsAsMeasured() {
        let heights: [String: CGFloat] = ["needs": 90, "work": 70, "done": 54]
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["needs", "work", "done"], rowHeights: heights), 161)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: ["a": 60, "b": 60]), 121)
        // One row: that row alone; no rows: nothing.
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["work"], rowHeights: heights), 70)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: [], rowHeights: heights), 0)
    }

    /// A row that has not measured itself yet counts as the 54 pt first-frame estimate.
    func testARowNotMeasuredYetCountsAsTheEstimate() {
        XCTAssertEqual(AgentsSection.estimatedRowHeight, 54)
        XCTAssertEqual(AgentsSection.hairlineHeight, 1)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b", "c"], rowHeights: [:]), 109)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b", "c"], rowHeights: ["a": 90]), 145)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a"], rowHeights: [:]), 54)
    }

    /// Plan ruling R2: rows already measured that move into first place change the floor,
    /// with no row measuring itself again.
    func testTwoMeasuredRowsSwappedIntoFirstPlaceChangeTheMinimum() {
        let heights: [String: CGFloat] = ["a": 54, "b": 54, "c": 90, "d": 70]
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b", "c", "d"], rowHeights: heights), 109)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["c", "d", "a", "b"], rowHeights: heights), 161)
    }
}
