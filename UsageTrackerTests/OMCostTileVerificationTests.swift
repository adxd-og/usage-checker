import XCTest
@testable import Omelette

/// Independent verification of `OMCostTile.caption`, derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)": "`OMCostTile` gets a `CostCopy` caption ... when any
/// contributing service is not pay-as-you-go". Not from `OMCostTileTests`. Focus: the
/// caption is nil exactly when every dollar-contributing service is pay-as-you-go, and
/// a provider that reports a window but has spent nothing this week or today does not
/// force the caption in either direction.
final class OMCostTileVerificationTests: XCTestCase {
    /// A window makes a service NOT pay-as-you-go by `CostCopy.isPayAsYouGo`.
    private func subscription(id: String, week: Double? = nil) -> ServiceSnapshot {
        Fixture.snapshot(
            id: id, displayName: id.capitalized,
            buckets: [Fixture.bucket(id: "five_hour", label: "Session", percent: 10, kind: .session)],
            weekCost: week
        )
    }

    private func payAsYouGo(id: String, week: Double? = nil) -> ServiceSnapshot {
        Fixture.snapshot(id: id, displayName: id.capitalized, buckets: [], weekCost: week)
    }

    func testAllPayAsYouGoContributorsYieldNilCaption() {
        XCTAssertNil(OMCostTile.caption(services: [payAsYouGo(id: "claude", week: 40), payAsYouGo(id: "codex", week: 2)]))
    }

    func testASingleSubscriptionContributorYieldsTheCaption() {
        XCTAssertEqual(OMCostTile.caption(services: [subscription(id: "claude", week: 40)]), CostCopy.apiEquivalent)
    }

    /// One subscription among several pay-as-you-go contributors is still enough.
    func testMixedContributorsStillGetTheCaption() {
        XCTAssertEqual(
            OMCostTile.caption(services: [
                payAsYouGo(id: "codex", week: 2), subscription(id: "claude", week: 40), payAsYouGo(id: "grok", week: 1),
            ]),
            CostCopy.apiEquivalent
        )
    }

    /// A subscription service present in `services` but with nothing spent (week nil,
    /// no today entry) is not "contributing" — it must not force the caption on its
    /// own when nobody else has dollars either.
    func testASubscriptionWithNothingSpentDoesNotForceTheCaptionAlone() {
        XCTAssertNil(OMCostTile.caption(services: [subscription(id: "claude", week: nil)], today: [:]))
    }

    /// `caption` reads `weekCost` and `today` independently: a subscription with no
    /// week total but a nonzero entry in `today` still counts as contributing.
    func testTodaysSpendAloneCountsAsContributingEvenWithNoWeekTotal() {
        XCTAssertEqual(
            OMCostTile.caption(services: [subscription(id: "claude", week: nil)], today: ["claude": 3.5]),
            CostCopy.apiEquivalent
        )
    }

    /// A provider not present in the tile's `services` array at all cannot contribute
    /// through `today`, even if the dictionary happens to carry its id — `caption`
    /// only ever filters `services`.
    func testATodayEntryForAProviderNotInServicesIsIgnored() {
        XCTAssertNil(OMCostTile.caption(services: [payAsYouGo(id: "codex", week: 2)], today: ["claude": 99]))
    }
}
