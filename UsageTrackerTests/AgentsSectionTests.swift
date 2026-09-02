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

    func testGroupTitles() {
        XCTAssertEqual(AgentsSection.groupTitle(.needsYou), "Needs you")
        XCTAssertEqual(AgentsSection.groupTitle(.working), "Working")
        XCTAssertEqual(AgentsSection.groupTitle(.done), "Done")
        XCTAssertEqual(AgentsSection.groupTitle(.idle), "Idle")
    }

    /// Only the two live states get a colour; a green "Done" heading shouts as
    /// loudly as the amber one that actually needs the user.
    func testGroupColours() {
        XCTAssertEqual(AgentsSection.groupColor(.needsYou), OMAgentColor.needsYou)
        XCTAssertEqual(AgentsSection.groupColor(.working), OMAgentColor.working)
        XCTAssertEqual(AgentsSection.groupColor(.done), Color.secondary)
        XCTAssertEqual(AgentsSection.groupColor(.idle), Color.secondary)
    }

    func testFinishedRowsDim() {
        XCTAssertEqual(AgentsSection.rowOpacity(.needsYou), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.working), 1, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.done), 0.7, accuracy: 0.001)
        XCTAssertEqual(AgentsSection.rowOpacity(.idle), 0.7, accuracy: 0.001)
    }
}
