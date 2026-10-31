import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, § 3.6, plan ruling R21, Codex's re-review: what the lower row's
/// agents card lists. With one provider and no agent source, an agents ear or the pet's "2 waiting"
/// click needs a card to reach, so that home page shows every session; a drilled-in page among several
/// stays without one (P3b R2).
final class ProviderGridRulesAgentsCardTests: XCTestCase {
    private func card(_ id: String?, of count: Int, sessions: Bool = true) -> ProviderGridRules.AgentsCard? {
        ProviderGridRules.agentsCard(serviceID: id, providerCount: count, hasSessions: sessions)
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
