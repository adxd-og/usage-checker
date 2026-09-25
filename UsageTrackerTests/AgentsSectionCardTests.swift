import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Principles 3 ("no uppercase micro labels") and
/// `Main.dc.html`: "Agents · 3 sessions" over one group card of rows split by
/// hairlines; each row says its own state.
final class AgentsSectionCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ name: String, _ state: AgentState, minutesAgo: Double) -> AgentSession {
        Fixture.agentSession(
            sessionID: name,
            projectName: name,
            state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    func testTheAllTabListsEveryStateInTurnInOneCard() {
        let sessions = [
            session("scratchpad", .idle, minutesAgo: 2),
            session("test", .needsYou, minutesAgo: 0),
            session("Usage tracker", .working, minutesAgo: 1),
            session("Jaravis", .done, minutesAgo: 5),
        ]
        XCTAssertEqual(AgentsSection.rows(sessions, grouped: true).map(\.projectName),
                       ["test", "Usage tracker", "Jaravis", "scratchpad"])
    }

    func testAProviderTabPutsWhatNeedsYouFirstThenTheMostRecent() {
        let sessions = [
            session("recent", .working, minutesAgo: 1),
            session("waiting", .needsYou, minutesAgo: 20),
            session("old", .done, minutesAgo: 40),
        ]
        XCTAssertEqual(AgentsSection.rows(sessions, grouped: false).map(\.projectName), ["waiting", "recent", "old"])
    }

    func testTheSectionIsAnAgentsHeadingOverAGroupCard() {
        XCTAssertEqual(AgentsSection.defaultTitle, "Agents")
        XCTAssertEqual(AgentsSection.headerInset, 4)
        XCTAssertEqual(AgentsSection.surface, .group)
    }
}
