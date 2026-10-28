import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1: a Claude switched off
/// is one of the dashboard's switched-off providers, so its history is not on offer, and
/// the picker's fallback never lands on a provider that is off. `polled` is what the last
/// poll asked for (`AppState.polledIDs`).
final class DashboardClaudeSwitchTests: XCTestCase {
    private func snapshot(_ services: [ServiceSnapshot]) -> UsageSnapshot {
        UsageSnapshot(
            services: services, fetchedAt: Date(timeIntervalSince1970: 1_793_100_000), isStale: false, lastError: nil
        )
    }

    private func reporting(_ id: String) -> ServiceSnapshot {
        Fixture.snapshot(id: id, buckets: [Fixture.bucket(id: "\(id)_session", percent: 10, kind: .session)])
    }

    // MARK: - Switched off

    func testClaudeSwitchedOffIsSwitchedOffLikeTheOthers() {
        XCTAssertEqual(
            DashboardState.switchedOff(polled: ["anthropic-admin", "codex", "antigravity", "grok"]),
            ["claude"]
        )
        XCTAssertEqual(
            DashboardState.switchedOff(polled: ["anthropic-admin"]),
            ["claude", "codex", "antigravity", "grok"]
        )
    }

    func testEverySwitchOnWithAKeyIsNothingSwitchedOff() {
        XCTAssertEqual(DashboardState.switchedOff(polled: ProviderCoordinator.serviceIDs), [])
    }

    func testAnAdminOrganisationWithoutAKeyIsSwitchedOff() {
        XCTAssertEqual(
            DashboardState.switchedOff(polled: ["claude", "codex", "antigravity", "grok"]), ["anthropic-admin"],
            "the key is what counts as on (spec: the admin key is something on), so no key is off"
        )
        XCTAssertEqual(DashboardState.switchedOff(polled: []), ProviderCoordinator.serviceIDs)
    }

    func testARecordedAdminHistoryWithoutAKeyIsNotOfferedAndNothingIsSelected() {
        let off = DashboardState.switchedOff(polled: [])
        let offered = DashboardState.availableServices(recorded: ["anthropic-admin"], snapshot: snapshot([]), disabled: off)
        XCTAssertEqual(offered, [])
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "anthropic-admin", available: offered, polled: []),
            DashboardState.noSelection
        )
    }

    func testClaudesHistoryIsNotOfferedWhileClaudeIsOff() {
        XCTAssertEqual(
            DashboardState.availableServices(
                recorded: ["claude", "codex"], snapshot: snapshot([reporting("codex")]), disabled: ["claude"]
            ),
            ["codex"]
        )
    }

    // MARK: - The fallback

    func testAClaudeSelectionMovesToTheProviderOnOffer() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "claude", available: ["codex"], polled: ["codex"]), "codex")
    }

    func testWithNothingOnOfferAClaudeSelectionGoesToAPolledProvider() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "claude", available: [], polled: ["grok", "codex"]), "codex",
            "the first polled provider by id; Claude used to stand still although it was off"
        )
    }

    func testWithNothingPolledTheSelectionIsNoProvider() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "claude", available: [], polled: []), DashboardState.noSelection
        )
        XCTAssertEqual(DashboardState.noSelection, "")
    }

    func testNoProviderGoesToClaudeOnceClaudeIsPolledAgain() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: DashboardState.noSelection, available: [], polled: ["claude", "codex"]),
            "claude"
        )
    }

    func testAnAdminOrganisationAloneIsWhereTheSelectionGoes() {
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "claude", available: [], polled: ["anthropic-admin"]),
            "anthropic-admin"
        )
    }

    func testAPolledSelectionStillStandsStillWithNothingOnOffer() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "codex", available: [], polled: ["claude", "codex"]), "codex")
    }
}
