import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Where it shows: the island's row ends a busy session's
/// second line with "212% · 3.4 GB", from 50 % CPU or 4 GB up; a row that needs the user shows
/// no suffix, so its badge and its question keep the width; a session without a tty shows
/// nothing (Decision 3). The Agents tab's row puts the figures beside the elapsed time.
final class AgentRowResourcesTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheIslandEndsTheSecondLineWithTheFigures() {
        XCTAssertFalse(AgentRowText.resourcesInTrailingColumn(.popover))
    }

    func testTheAgentsTabPutsThemBesideTheElapsedTime() {
        XCTAssertTrue(AgentRowText.resourcesInTrailingColumn(.dashboard))
    }

    func testVoiceOverReadsTheFiguresLast() {
        let session = Fixture.agentSession(projectName: "Usage tracker", state: .working, stateSince: now.addingTimeInterval(-14 * 60))
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now, resources: "212% · 3.4 GB"),
            "Usage tracker, Claude Code, Working, for 14 minutes, 212% · 3.4 GB"
        )
    }

    func testWithoutFiguresTheLabelIsAsBefore() {
        let session = Fixture.agentSession(projectName: "Usage tracker", state: .working, stateSince: now.addingTimeInterval(-14 * 60))
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now, resources: nil),
            "Usage tracker, Claude Code, Working, for 14 minutes"
        )
    }

    func testAnIslandRowsSuffixComesFromItsTTY() {
        let busy = Fixture.agentSession(sessionID: "a", host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab))
        let waiting = Fixture.agentSession(sessionID: "b", host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.otherTab))
        let panel = Fixture.agentSession(sessionID: "c", host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil))
        let byTTY: [String: AgentResourceRules.Figures] = [
            F.tab: AgentResourceRules.Figures(cpuPercent: 212.4, memoryBytes: 3_650_722_202),
            F.otherTab: AgentResourceRules.Figures(cpuPercent: 0.5, memoryBytes: 2533 * F.mb),
        ]
        // What the monitor publishes: each session's figures by id (`AgentResourceMonitor.bySession`).
        let figures = AgentResourceRules.bySession([busy, waiting, panel], byTTY: byTTY)
        XCTAssertEqual(AgentsSection.resourceSuffix(for: busy, figures: figures, scale: .perCore, cores: 10), "212% · 3.4 GB")
        XCTAssertEqual(AgentsSection.resourceSuffix(for: busy, figures: figures, scale: .wholeMac, cores: 10), "21% · 3.4 GB")
        XCTAssertNil(
            AgentsSection.resourceSuffix(for: waiting, figures: figures, scale: .perCore, cores: 10),
            "a waiting session at 2.5 GB stays quiet"
        )
        XCTAssertNil(AgentsSection.resourceSuffix(for: panel, figures: figures, scale: .perCore, cores: 10), "an IDE panel shows nothing")
    }

    /// Review F3: the predicate the suffix keys on — the row needs the user
    /// (`state == .needsYou`: a permission request, a question, a plan) or holds Allow / Deny.
    func testARowCarriesAnActionWhenItNeedsTheUserOrHoldsAllowAndDeny() {
        XCTAssertTrue(AgentRowText.carriesAction(Fixture.agentSession(state: .needsYou)))
        var held = Fixture.agentSession(state: .working)
        held.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        XCTAssertTrue(AgentRowText.carriesAction(held), "Allow and Deny on the row")
        XCTAssertFalse(AgentRowText.carriesAction(Fixture.agentSession(state: .working)))
        XCTAssertFalse(AgentRowText.carriesAction(Fixture.agentSession(state: .done)))
        XCTAssertFalse(AgentRowText.carriesAction(Fixture.agentSession(state: .idle)))
    }

    /// § Where it shows (review F3): a row that needs the user shows no suffix, at 4 GB or at
    /// 212%: its badge and its question keep the island's half column.
    func testARowThatNeedsTheUserShowsNoSuffix() {
        let host = AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        let asking = Fixture.agentSession(sessionID: "q", state: .needsYou, host: host)
        let working = Fixture.agentSession(sessionID: "q", state: .working, host: host)
        let atFourGB = AgentResourceRules.bySession(
            [asking], byTTY: [F.tab: AgentResourceRules.Figures(cpuPercent: 3, memoryBytes: 4_294_967_296)]
        )
        let at212 = AgentResourceRules.bySession(
            [asking], byTTY: [F.tab: AgentResourceRules.Figures(cpuPercent: 212.4, memoryBytes: 634 * F.mb)]
        )
        XCTAssertNil(AgentsSection.resourceSuffix(for: asking, figures: atFourGB, scale: .perCore, cores: 10))
        XCTAssertNil(AgentsSection.resourceSuffix(for: asking, figures: at212, scale: .perCore, cores: 10))
        XCTAssertEqual(
            AgentsSection.resourceSuffix(for: working, figures: at212, scale: .perCore, cores: 10), "212% · 634 MB",
            "the same session once answered shows them"
        )
    }
}
