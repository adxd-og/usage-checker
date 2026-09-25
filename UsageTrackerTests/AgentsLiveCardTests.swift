import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Agents" ("Live full width") and § Components, "Agent
/// row (dashboard)": the Live card lists what is running in state order. Each row has
/// its provider logo with a state dot at the logo's bottom-right, at the mockup's
/// dashboard size.
final class AgentsLiveCardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ name: String, _ state: AgentState, source: AgentSource = .claude, minutesAgo: Double) -> AgentSession {
        Fixture.agentSession(
            sessionID: name,
            source: source,
            projectName: name,
            state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    func testRowsRunInStateOrderAsTheMockupDrawsThem() {
        let sessions = [
            session("scratchpad", .idle, minutesAgo: 2),
            session("Usage tracker", .working, minutesAgo: 1),
            session("orion-gemini", .done, source: .codex, minutesAgo: 5),
            session("test", .needsYou, minutesAgo: 0),
        ]
        XCTAssertEqual(
            AgentsLiveCard.rows(sessions).map(\.projectName),
            ["test", "Usage tracker", "orion-gemini", "scratchpad"]
        )
    }

    func testEveryRowWearsItsProviderLogo() {
        XCTAssertTrue(AgentsLiveCard.showsProviderIcon)
    }

    func testRowsAreTheDashboardSizeNotThePopovers() {
        XCTAssertEqual(AgentsLiveCard.rowMetrics, .dashboard)
    }
}
