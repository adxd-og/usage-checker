import XCTest
@testable import Omelette

/// Verifies the Needs-you placement (owner, 2026-11-02) beyond the executor's unit
/// checks: the whole second line as the row assembles it, the hosts' metrics, the
/// provider tab, approximate sessions with no activity, and the states that must not
/// change in either size.
final class AgentRowNeedsYouPlacementVerificationTests: XCTestCase {
    /// The second line exactly as `OMAgentRow.subtitleText` assembles it.
    private func secondLine(_ session: AgentSession, metrics: OMAgentRowMetrics, providerTab: Bool) -> String {
        guard let badge = AgentRowText.subtitleBadge(session.state, metrics: metrics) else {
            return AgentRowText.rowSubtitle(for: session, providerTab: providerTab)
        }
        return badge + AgentRowText.subtitleTail(AgentRowText.badgedSubtitle(for: session))
    }

    // MARK: hosts

    func testTheIslandAndPanelHostDrawsAtPopoverMetricsAndTheLiveCardAtDashboardMetrics() {
        XCTAssertEqual(OMAgentRow.defaultMetrics, .popover)
        XCTAssertEqual(AgentsLiveCard.rowMetrics, .dashboard)
        XCTAssertNotEqual(OMAgentRowMetrics.popover, OMAgentRowMetrics.dashboard)
    }

    // MARK: popover size

    func testPopoverNeedsYouOpensTheSecondLineFollowedByTheActivity() {
        let s = Fixture.agentSession(state: .needsYou, activity: "Bash: ls")
        XCTAssertEqual(secondLine(s, metrics: .popover, providerTab: false), "Needs you · Bash: ls")
    }

    func testPopoverNeedsYouWithNoActivityIsNeedsYouAlone() {
        for activity in [nil, "", "   ", "\n\t "] as [String?] {
            let s = Fixture.agentSession(state: .needsYou, activity: activity)
            let line = secondLine(s, metrics: .popover, providerTab: false)
            XCTAssertEqual(line, "Needs you", "activity \(String(describing: activity))")
            XCTAssertFalse(line.contains("Needs approval"))
        }
    }

    func testPopoverApproximateNeedsYouKeepsTheMarkBeforeTheActivity() {
        let s = Fixture.agentSession(state: .needsYou, activity: "Bash: ls", isApproximate: true)
        XCTAssertEqual(secondLine(s, metrics: .popover, providerTab: false), "Needs you · ≈ Bash: ls")
    }

    func testPopoverApproximateNeedsYouWithNoActivityIsStillNeedsYouAlone() {
        let s = Fixture.agentSession(state: .needsYou, activity: nil, isApproximate: true)
        XCTAssertEqual(secondLine(s, metrics: .popover, providerTab: false), "Needs you")
    }

    func testActivityIsTrimmedBeforeItFollowsTheBadge() {
        let s = Fixture.agentSession(state: .needsYou, activity: "  Bash: ls \n")
        XCTAssertEqual(secondLine(s, metrics: .popover, providerTab: false), "Needs you · Bash: ls")
    }

    // MARK: provider tab (providerTab: true, no provider icon)

    func testProviderTabNeedsYouInThePopoverCarriesNoStateWordBesideTheBadge() {
        let withActivity = Fixture.agentSession(state: .needsYou, activity: "Which option?")
        XCTAssertEqual(secondLine(withActivity, metrics: .popover, providerTab: true), "Needs you · Which option?")
        let bare = Fixture.agentSession(state: .needsYou, activity: nil)
        XCTAssertEqual(secondLine(bare, metrics: .popover, providerTab: true), "Needs you")
    }

    func testProviderTabStateWordsForOtherStatesAreUntouched() {
        for metrics in [OMAgentRowMetrics.popover, .dashboard] {
            let done = Fixture.agentSession(state: .done, activity: "Probe whether")
            XCTAssertEqual(secondLine(done, metrics: metrics, providerTab: true), "Done · Probe whether")
            let working = Fixture.agentSession(state: .working, activity: nil)
            XCTAssertEqual(secondLine(working, metrics: metrics, providerTab: true), "Working")
            let idle = Fixture.agentSession(state: .idle, activity: "Edit a.swift", isApproximate: true)
            XCTAssertEqual(secondLine(idle, metrics: metrics, providerTab: true), "≈ Idle · Edit a.swift")
        }
    }

    // MARK: dashboard size unchanged

    func testDashboardKeepsNeedsYouOnTheTitleAndTheSecondLineAsBefore() {
        XCTAssertEqual(AgentRowText.titleBadge(.needsYou), "Needs you")
        XCTAssertTrue(AgentRowText.needsYouOnTitle(.dashboard))
        let withActivity = Fixture.agentSession(state: .needsYou, activity: "Bash: ls")
        XCTAssertEqual(secondLine(withActivity, metrics: .dashboard, providerTab: false), "Bash: ls")
        XCTAssertEqual(secondLine(withActivity, metrics: .dashboard, providerTab: true), "Bash: ls")
        let bare = Fixture.agentSession(state: .needsYou, activity: nil)
        XCTAssertEqual(secondLine(bare, metrics: .dashboard, providerTab: false), "Needs approval")
        let approx = Fixture.agentSession(state: .needsYou, activity: "Bash: ls", isApproximate: true)
        XCTAssertEqual(secondLine(approx, metrics: .dashboard, providerTab: false), "≈ Bash: ls")
    }

    // MARK: other states unchanged in both sizes

    func testNoStateButNeedsYouEverGetsABadgeOrMovesOffItsSubtitle() {
        for metrics in [OMAgentRowMetrics.popover, .dashboard] {
            for state in AgentState.allCases where state != .needsYou {
                XCTAssertNil(AgentRowText.subtitleBadge(state, metrics: metrics), "\(state)")
                XCTAssertNil(AgentRowText.titleBadge(state), "\(state)")
                let withActivity = Fixture.agentSession(state: state, activity: "Edit a.swift")
                XCTAssertEqual(secondLine(withActivity, metrics: metrics, providerTab: false), "Edit a.swift")
                let bare = Fixture.agentSession(state: state, activity: nil)
                XCTAssertEqual(
                    secondLine(bare, metrics: metrics, providerTab: false),
                    AgentRowText.statePhrase(state)
                )
            }
        }
    }

    func testAccessibilityLabelStillSaysTheStatePhraseForANeedsYouSession() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 300)
        let s = Fixture.agentSession(state: .needsYou, activity: nil)
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: s, now: now),
            "Usage tracker, Claude Code, Needs approval, for 5 minutes"
        )
        let a = Fixture.agentSession(state: .needsYou, activity: "Bash: ls", isApproximate: true)
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: a, now: now),
            "Usage tracker, Claude Code, Needs approval, approximately Bash: ls, for 5 minutes"
        )
    }
}
