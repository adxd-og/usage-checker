import XCTest
@testable import Omelette

/// The two rules that decide which provider the dashboard, the floating window and the
/// popover's burn row are talking about. Both are pure and static so they can be tested
/// without driving SwiftUI or the real history log.
final class DashboardSelectionTests: XCTestCase {

    private func snapshot(_ services: [ServiceSnapshot]) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: Date(), isStale: false, lastError: nil)
    }

    private func reporting(_ id: String) -> ServiceSnapshot {
        Fixture.snapshot(id: id, buckets: [Fixture.bucket(id: "\(id)_session", percent: 10, kind: .session)])
    }

    /// Present in the snapshot but with nothing to show — a signed-out Claude, which is
    /// what every account that never signs in looks like.
    private func silent(_ id: String) -> ServiceSnapshot {
        Fixture.snapshot(id: id, plan: nil, state: .notSignedIn)
    }

    // MARK: - What the picker offers

    func testAProviderReportingNowIsOfferedEvenWithNoHistoryYet() {
        // The case that stranded a Grok-only user: history is written only for providers
        // that have polled `.ok`, so on first run there is none at all.
        let options = DashboardState.availableServices(
            recorded: [],
            snapshot: snapshot([silent("claude"), reporting("grok")]),
            disabled: []
        )
        XCTAssertEqual(options, ["grok"])
    }

    func testAProviderWithHistoryButNoDataRightNowIsStillOffered() {
        // Signed out today, but the past is worth reading.
        let options = DashboardState.availableServices(
            recorded: ["claude", "codex"],
            snapshot: snapshot([silent("claude"), silent("codex")]),
            disabled: []
        )
        XCTAssertEqual(options, ["claude", "codex"])
    }

    func testAProviderSwitchedOffInSettingsIsNotOffered() {
        let options = DashboardState.availableServices(
            recorded: ["claude", "codex", "grok"],
            snapshot: snapshot([silent("claude"), reporting("grok")]),
            disabled: ["grok"]
        )
        XCTAssertEqual(options, ["claude", "codex"])
    }

    func testLiveProvidersLeadAndNothingIsListedTwice() {
        let options = DashboardState.availableServices(
            recorded: ["claude", "grok"],
            snapshot: snapshot([silent("claude"), reporting("grok")]),
            disabled: []
        )
        XCTAssertEqual(options, ["grok", "claude"])
        XCTAssertEqual(options.count, Set(options).count)
    }

    func testAPayAsYouGoProviderCountsAsHavingData() {
        // No rate windows at all, just a dollar figure — the menu bar shows it, so the
        // picker has to offer it.
        let payg = Fixture.snapshot(id: "claude", buckets: [], weekCost: 41.37)
        XCTAssertEqual(
            DashboardState.availableServices(recorded: [], snapshot: snapshot([payg]), disabled: []),
            ["claude"]
        )
    }

    // MARK: - Healing a selection that fell off the list

    func testASelectionThatIsStillOnOfferIsLeftAlone() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "codex", available: ["claude", "codex"]),
            "codex"
        )
    }

    func testASelectionThatFellOffMovesToTheFirstOption() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "claude", available: ["grok"]),
            "grok"
        )
    }

    func testWithNothingToHealToTheSelectionStandsStill() {
        // Before the first poll there is nothing to move to, and blanking the picker
        // would be worse than a selection that is briefly wrong.
        XCTAssertEqual(DashboardState.healedSelection(stored: "claude", available: []), "claude")
    }
}

/// A refresh pass may only publish while it is still the newest one and still about the
/// provider it started for. `Task.cancel()` is cooperative and an actor call already in
/// flight runs to completion regardless, so this check is what keeps one provider's
/// numbers off another's tab.
final class DashboardRefreshPassTests: XCTestCase {
    private func pass(_ service: String, _ generation: Int) -> DashboardState.RefreshPass {
        DashboardState.RefreshPass(service: service, generation: generation)
    }

    func testThePassThatIsStillCurrentPublishes() {
        XCTAssertTrue(DashboardState.canPublish(
            pass: pass("claude", 3), currentService: "claude", currentGeneration: 3
        ))
    }

    func testAPassSupersededByANewerRefreshDoesNot() {
        // Its own result is older than the one already on screen.
        XCTAssertFalse(DashboardState.canPublish(
            pass: pass("claude", 3), currentService: "claude", currentGeneration: 4
        ))
    }

    func testAPassStartedForAnotherProviderDoesNot() {
        // The poll path calls `refreshDerived()` with no generation of its own, so the
        // service is the half that catches a switch mid-scan.
        XCTAssertFalse(DashboardState.canPublish(
            pass: pass("claude", 3), currentService: "grok", currentGeneration: 3
        ))
    }

    func testBothHaveToMatch() {
        XCTAssertFalse(DashboardState.canPublish(
            pass: pass("claude", 3), currentService: "grok", currentGeneration: 4
        ))
    }
}
