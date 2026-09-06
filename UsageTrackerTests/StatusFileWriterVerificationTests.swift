import XCTest
@testable import Omelette

/// Independent verification of `StatusFileWriter.build`, derived from the spec's
/// sentence "providers without a log are absent, not 0" and the plan's Task 2, not
/// from `StatusFileWriterTests`. Focus: a service with no entry at all in the `costs`
/// dictionary (as opposed to one with a `CostEntry` of zero), and the fallback to a
/// service's own cached `weekCost` when the cost gatherer produced nothing for it.
final class StatusFileWriterVerificationTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func service(
        id: String, buckets: [UsageBucket] = [], weekCost: Double? = nil, state: ServiceState = .ok
    ) -> ServiceSnapshot {
        Fixture.snapshot(id: id, displayName: id.capitalized, buckets: buckets, weekCost: weekCost, state: state, at: now)
    }

    /// Grok, say, has no local cost log at all: `StatusCosts.gather` never puts a
    /// `CostEntry` in the dictionary for it. `build` must leave `todayCost`,
    /// `weekCost` and `todayTokens` all `nil` — not zero, which would print or be read
    /// by an MCP client as "spent nothing today" instead of "no log for this provider".
    func testAServiceMissingFromTheCostsDictionaryHasAbsentNotZeroDollars() {
        let snapshot = StatusFileWriter.build(
            services: [service(id: "grok", buckets: [Fixture.bucket(id: "w", percent: 10, kind: .session)])],
            costs: [:], // grok is not a key at all
            agents: .none, now: now
        )

        let grok = snapshot.services.first
        XCTAssertNil(grok?.todayCost, "no log means no number, not $0.00")
        XCTAssertNil(grok?.weekCost)
        XCTAssertNil(grok?.todayTokens)
        XCTAssertNil(grok?.apiEquivalent, "nothing to qualify when there are no dollars")
    }

    /// Contrast: a real `CostEntry` of exactly zero (the provider has a log and simply
    /// spent nothing today) must come through as the number 0, not disappear.
    func testAZeroCostEntryIsZeroNotAbsent() {
        let snapshot = StatusFileWriter.build(
            services: [service(id: "claude", buckets: [Fixture.bucket(id: "w", percent: 10, kind: .session)])],
            costs: ["claude": .init(todayCost: 0, weekCost: 0, todayTokens: 0)],
            agents: .none, now: now
        )

        let claude = snapshot.services.first
        XCTAssertEqual(claude?.todayCost, 0, "a quiet day with a log still reports the log")
        XCTAssertEqual(claude?.weekCost, 0)
        XCTAssertEqual(claude?.todayTokens, 0)
        XCTAssertNotNil(claude?.apiEquivalent, "hasDollars is true even at exactly zero")
    }

    /// When the cost gatherer produced no entry for a service, `build` still falls
    /// back to the service's own cached `weekCost` (the popover's figure, per the
    /// spec's "reuse the popover's cached weekCost" note) — `todayCost` stays absent
    /// (there is no daily figure to fall back to) while `weekCost` is populated, and
    /// `apiEquivalent` is still computed from that non-nil dollar figure.
    func testNoCostEntryFallsBackToTheServicesOwnWeekCostForPayAsYouGo() {
        let payg = service(id: "claude", buckets: [], weekCost: 63.40, state: .ok)
        XCTAssertTrue(StatusFileWriter.isPayAsYouGo(payg), "no reported windows, a week cost: this is PAYG")

        let snapshot = StatusFileWriter.build(services: [payg], costs: [:], agents: .none, now: now)

        let claude = snapshot.services.first
        XCTAssertNil(claude?.todayCost, "no CostEntry means no daily figure to fall back to")
        XCTAssertEqual(claude?.weekCost, 63.40, "the service's own cached week cost is used")
        XCTAssertEqual(claude?.apiEquivalent, false, "a PAYG account's dollars are close to the real bill")
    }
}
