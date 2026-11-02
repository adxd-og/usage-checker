import XCTest
@testable import Omelette

/// Where Needs you sits on an agent row (owner, 2026-11-02): in the island and the
/// panel (`.popover` metrics) the title carries only the project and Needs you opens
/// the second line in the accent, because in the island's 220 pt column the title's
/// badge left the project "Us…ker"; the dashboard's wide row (`.dashboard`) keeps the
/// badge on the title.
final class AgentRowNeedsYouPlacementTests: XCTestCase {
    func testTheDashboardRowKeepsNeedsYouOnTheTitle() {
        XCTAssertTrue(AgentRowText.needsYouOnTitle(.dashboard))
        XCTAssertNil(AgentRowText.subtitleBadge(.needsYou, metrics: .dashboard))
    }

    func testTheIslandRowMovesNeedsYouToTheSecondLine() {
        XCTAssertFalse(AgentRowText.needsYouOnTitle(.popover))
        XCTAssertEqual(AgentRowText.subtitleBadge(.needsYou, metrics: .popover), "Needs you")
    }

    func testOnlyNeedsYouGetsASubtitleBadge() {
        XCTAssertNil(AgentRowText.subtitleBadge(.working, metrics: .popover))
        XCTAssertNil(AgentRowText.subtitleBadge(.done, metrics: .popover))
        XCTAssertNil(AgentRowText.subtitleBadge(.idle, metrics: .popover))
    }

    func testTheSecondLineNeverSaysNeedsYouTwice() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: "Which option do you prefer?")
        XCTAssertFalse(AgentRowText.rowSubtitle(for: waiting, providerTab: true).contains("Needs you"))
        XCTAssertFalse(AgentRowText.rowSubtitle(for: waiting, providerTab: false).contains("Needs you"))
    }

    func testTheBadgeIsFollowedByTheSubtitleAfterADot() {
        XCTAssertEqual(AgentRowText.subtitleTail("Which option do you prefer?"), " · Which option do you prefer?")
    }

    func testWithNoSubtitleTheBadgeStandsAlone() {
        XCTAssertEqual(AgentRowText.subtitleTail(""), "")
    }

    func testANeedsYouSessionWithNoActivityLeavesTheBadgeAlone() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: nil)
        XCTAssertEqual(AgentRowText.badgedSubtitle(for: waiting), "")
    }

    func testABadgedLineCarriesTheActivity() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: "Bash: ls")
        XCTAssertEqual(AgentRowText.badgedSubtitle(for: waiting), "Bash: ls")
    }

    func testABadgedLineKeepsTheApproximateMark() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: "Bash: ls", isApproximate: true)
        XCTAssertEqual(AgentRowText.badgedSubtitle(for: waiting), "≈ Bash: ls")
    }

    func testAWhitespaceOnlyActivityLeavesTheBadgeAlone() {
        let waiting = Fixture.agentSession(state: .needsYou, activity: "  \n ")
        XCTAssertEqual(AgentRowText.badgedSubtitle(for: waiting), "")
    }

    func testTheIslandTitleCarriesNoBadge() {
        XCTAssertNil(AgentRowText.titleBadge(.needsYou, metrics: .popover))
    }

    func testTheDashboardTitleCarriesNeedsYou() {
        XCTAssertEqual(AgentRowText.titleBadge(.needsYou, metrics: .dashboard), "Needs you")
    }

    func testNoOtherStateGetsATitleBadgeInEitherRow() {
        for state: AgentState in [.working, .done, .idle] {
            XCTAssertNil(AgentRowText.titleBadge(state, metrics: .popover), "\(state)")
            XCTAssertNil(AgentRowText.titleBadge(state, metrics: .dashboard), "\(state)")
        }
    }

    func testNeedsYouIsShownExactlyOnceAndNothingElseIsShown() {
        for state in AgentState.allCases {
            for metrics: OMAgentRowMetrics in [.popover, .dashboard] {
                let shown = [AgentRowText.titleBadge(state, metrics: metrics),
                             AgentRowText.subtitleBadge(state, metrics: metrics)].compactMap { $0 }
                XCTAssertEqual(shown.count, state == .needsYou ? 1 : 0, "\(state) \(metrics)")
            }
        }
    }
}
