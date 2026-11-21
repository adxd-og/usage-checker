import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Where it shows, with its 2026-11-21 amendment: the Agents
/// tab's Live card keeps its rows in state order (needs you, working, done, idle; most recent
/// first inside a state), with no sort, no stored order and no switch. These tests pin what the
/// removed CPU-order tests used to pin from the State side: a row that holds Allow / Deny is not
/// lifted out of its state, recency decides inside a state, and the card's order is the island's
/// All tab order, whichever way the store lists the sessions.
final class NoLiveSortVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        _ name: String, _ state: AgentState, source: AgentSource = .claude, minutesAgo: Double
    ) -> AgentSession {
        Fixture.agentSession(
            sessionID: name, source: source, projectName: name, state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    /// A working row that holds Allow / Deny (`carriesAction`) sits among the working rows by
    /// recency: it is not hoisted to the top the way the CPU order once hoisted it.
    func testAWorkingRowHoldingAllowAndDenyStaysAmongTheWorkingRowsByRecency() {
        var held = session("held", .working, minutesAgo: 10)
        held.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        XCTAssertTrue(AgentRowText.carriesAction(held))
        let newer = session("newer", .working, minutesAgo: 1)
        let needs = session("needs", .needsYou, minutesAgo: 20)

        XCTAssertEqual(
            AgentsLiveCard.rows([held, newer, needs]).map(\.projectName),
            ["needs", "newer", "held"],
            "needs you leads; the held row is the older working row, so it follows the newer one"
        )
    }

    /// Most recent first inside each state, and the same list whichever order the store hands
    /// the sessions over in.
    func testRecencyOrdersEachStateAndTheInputOrderDoesNotMatter() {
        let live = [
            session("w-old", .working, minutesAgo: 9),
            session("w-new", .working, minutesAgo: 2),
            session("d-old", .done, minutesAgo: 8),
            session("d-new", .done, minutesAgo: 3),
            session("i-old", .idle, minutesAgo: 7),
            session("i-new", .idle, minutesAgo: 4),
            session("n-old", .needsYou, minutesAgo: 6),
            session("n-new", .needsYou, minutesAgo: 5),
        ]
        let expected = ["n-new", "n-old", "w-new", "w-old", "d-new", "d-old", "i-new", "i-old"]

        XCTAssertEqual(AgentsLiveCard.rows(live).map(\.projectName), expected)
        XCTAssertEqual(AgentsLiveCard.rows(live.reversed()).map(\.projectName), expected)
        XCTAssertEqual(
            AgentsLiveCard.rows([live[3], live[6], live[0], live[5], live[1], live[7], live[2], live[4]]).map(\.projectName),
            expected
        )
    }

    /// § Where it shows: "the popover's All tab, whichever source the filter shows". The card
    /// lists exactly the island's All tab rows (`AgentsSection.rows(_, grouped: true)`), sources
    /// mixed.
    func testTheCardListsTheSameRowsInTheSameOrderAsTheIslandsAllTab() {
        var held = session("held", .working, source: .codex, minutesAgo: 12)
        held.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        let live = [
            session("idle-codex", .idle, source: .codex, minutesAgo: 1),
            held,
            session("work-claude", .working, source: .claude, minutesAgo: 3),
            session("done-codex", .done, source: .codex, minutesAgo: 2),
            session("needs-claude", .needsYou, source: .claude, minutesAgo: 30),
            session("needs-codex", .needsYou, source: .codex, minutesAgo: 15),
        ]

        XCTAssertEqual(
            AgentsLiveCard.rows(live).map(\.id),
            AgentsSection.rows(live, grouped: true).map(\.id)
        )
        XCTAssertEqual(
            AgentsLiveCard.rows(live).map(\.projectName),
            ["needs-codex", "needs-claude", "work-claude", "held", "done-codex", "idle-codex"]
        )
    }
}
