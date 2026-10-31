import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, § 3.6, plan ruling R21, Codex's re-review: what the lower row's
/// agents card lists. With one provider and no agent source, an agents ear or the pet's "2 waiting"
/// click needs a card to reach, so that home page shows every session; a drilled-in page among several
/// stays without one (P3b R2).
final class ProviderGridRulesAgentsCardTests: XCTestCase {
    /// With `sessions`, the page's own source's only: `card(_:of:sources:)` has the others.
    private func card(_ id: String?, of count: Int, sessions: Bool = true) -> ProviderGridRules.AgentsCard? {
        let own = id.flatMap(AgentSource.init(rawValue:)) ?? .claude
        return card(id, of: count, sources: sessions ? [own] : [])
    }

    private func card(_ id: String?, of count: Int, sources: Set<AgentSource>) -> ProviderGridRules.AgentsCard? {
        ProviderGridRules.agentsCard(serviceID: id, providerCount: count, sessionSources: sources)
    }

    func testAllListsEverySessionWithOrWithoutAny() {
        XCTAssertEqual(card(nil, of: 4), .allSessions)
        XCTAssertEqual(card(nil, of: 4, sessions: false), .allSessions)
    }

    func testAProviderWithAgentsListsItsOwnOnAnyPage() {
        XCTAssertEqual(card("claude", of: 4), .provider(.claude))
        XCTAssertEqual(card("codex", of: 1, sessions: false), .provider(.codex))
    }

    func testADrilledInProviderWithoutAgentsHasNoCard() {
        XCTAssertNil(card("grok", of: 4))
        XCTAssertNil(card("antigravity", of: 2))
    }

    func testAHomePageWithoutAgentsShowsEverySessionWhenThereAreAny() {
        XCTAssertEqual(card("grok", of: 1), .allSessions)
        XCTAssertEqual(card("antigravity", of: 1), .allSessions)
    }

    func testAHomePageWithoutAgentsAndNoSessionsHasNoCard() {
        XCTAssertNil(card("grok", of: 1, sessions: false))
    }

    private func session(id: String, source: AgentSource, at now: Date) -> AgentSession {
        AgentSession(
            sessionID: id, source: source, projectName: "Projects / orion",
            cwd: "/Users/tester/Projects/orion", state: .needsYou, activity: nil,
            stateSince: now, lastEventAt: now, startedAt: now,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil), isApproximate: true
        )
    }

    // MARK: - A sole provider's home page (whole-branch review of 4.0, ruling R6)

    func testASoleProvidersHomePageShowsEverySessionWhenAnotherSourceHasSome() {
        XCTAssertEqual(card("claude", of: 1, sources: [.codex]), .allSessions)
        XCTAssertEqual(card("codex", of: 1, sources: [.claude]), .allSessions)
        XCTAssertEqual(card("claude", of: 1, sources: [.claude, .codex]), .allSessions)
    }

    func testASoleProvidersHomePageListsItsOwnWhenTheyAreAllThereIs() {
        XCTAssertEqual(card("claude", of: 1, sources: [.claude]), .provider(.claude))
        XCTAssertEqual(card("codex", of: 1, sources: []), .provider(.codex))
    }

    func testAPageAmongSeveralListsItsOwnWhateverElseRuns() {
        XCTAssertEqual(card("claude", of: 2, sources: [.codex]), .provider(.claude))
        XCTAssertEqual(card("codex", of: 4, sources: [.claude, .codex]), .provider(.codex))
    }

    // MARK: - Under the empty body (whole-branch review of 4.0, ruling R5)

    private func emptyCard(_ id: String?, of count: Int, sessions: Bool) -> ProviderGridRules.AgentsCard? {
        ProviderGridRules.agentsCard(
            serviceID: id, providerCount: count, sessionSources: sessions ? [.claude] : [], bodyIsEmpty: true
        )
    }

    func testWithNoTilesEverySessionHasACardWhenThereAreAny() {
        XCTAssertEqual(emptyCard(nil, of: 0, sessions: true), .allSessions)
    }

    func testWithNoTilesAndNoSessionsThereIsNoCard() {
        XCTAssertNil(emptyCard(nil, of: 0, sessions: false))
    }

    /// Nothing on wins over services the poll that switched the last provider off has not dropped.
    func testAProviderStillListedDoesNotNarrowTheCardUnderTheEmptyBody() {
        XCTAssertEqual(emptyCard("claude", of: 2, sessions: true), .allSessions)
        XCTAssertEqual(emptyCard("grok", of: 3, sessions: true), .allSessions)
        XCTAssertNil(emptyCard("claude", of: 1, sessions: false))
    }

    /// The whole path of the finding: every provider off, two sessions waiting. The pet says
    /// "2 waiting", the body says nothing is on, and the click's card is there to reach.
    func testEveryProviderOffWithSessionsWaitingTheClickReachesTheirCard() throws {
        let now = Date(timeIntervalSince1970: 1_793_022_480)
        let sessions = ["a", "b"].map { session(id: $0, source: .codex, at: now) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let mood = PetMoodRules.mood(
            PetMoodInput(sessions: sessions, services: [], enabledIDs: [], claudeBinaryFound: true, keepAwake: .idle),
            now: now, calendar: calendar
        )
        guard case .needsYou(let waiting) = mood else { return XCTFail("\(mood)") }
        XCTAssertEqual(waiting.count, 2)

        let body = PopoverView.emptyBody(pollsNothing: true, services: [])
        XCTAssertEqual(body, .nothingOn)
        let shown = ProviderGridRules.agentsCard(
            serviceID: nil, providerCount: 0, sessionSources: Set(sessions.map(\.source)), bodyIsEmpty: body != nil
        )
        XCTAssertEqual(shown, .allSessions)
        XCTAssertTrue(PetActionRules.revealReady(.agents, agentsCardShown: shown != nil, moving: false))
    }

    func testTheRowSplitsOnlyWhenThereIsACard() {
        let columns = ProviderGridRules.columns(bodyWidth: 640, showsHabitat: true)
        let with = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: card("grok", of: 1) != nil)
        XCTAssertEqual(with.agentsWidth, columns.half)
        XCTAssertEqual(with.otherWidth, columns.half)
        let without = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: card("grok", of: 1, sessions: false) != nil)
        XCTAssertNil(without.agentsWidth)
        XCTAssertEqual(without.otherWidth, columns.right)
    }
}
