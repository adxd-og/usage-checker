import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 5. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "Floating panel: `FloatingMiniLayout.Content` carries the retained state; the view
/// dims ring and bars to 0.55, hides the pace marker, shows the tile's chip."
///
/// The executor's `FloatingMiniRetainedTests` covers a windowed retained service. This
/// file adds a service built through the real `AppState.retainingLastGoodServices`
/// pipeline (rather than a hand-built `Fixture.snapshot(state:)`), a multi-window
/// service where only the hero's own bucket needs to carry the retained stamp
/// correctly through `rows`, and the windowless pay-as-you-go case the executor's file
/// does not touch at all — which P1 does not yet fix (that is P4's "PAYG branch" per
/// the spec's shared-file rule), so this pins the current, documented gap rather than
/// asserting a fix that was never promised here.
final class FloatingPanelRetentionVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_300_000)
    private var t1: Date { t0.addingTimeInterval(3600) }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    func testAServiceRetainedThroughTheRealPipelineCarriesItsStamp() throws {
        let good = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 44, resetsAt: t1.addingTimeInterval(3600), kind: .session)],
            at: t0
        )
        let failed = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .error, stateMessage: "500", at: t1)
        let merged = AppState.retainingLastGoodServices(
            previous: poll([good], at: t0), next: poll([failed], at: t1), stored: [:]
        )
        let retainedService = try XCTUnwrap(merged.services.first)

        let content = FloatingMiniLayout.content(for: retainedService)
        XCTAssertEqual(content.retainedAt, t0)
        XCTAssertEqual(FloatingMiniLayout.numbersOpacity(content), 0.55)
        XCTAssertEqual(content.hero?.utilization, 44, "the frozen number, not a reset to zero")
    }

    func testEveryRowSharesTheSameRetainedStampAsTheHero() {
        // The stamp lives on `Content`, not per-bucket — every row a retained service
        // shows has to dim under the same age, not just the hero.
        let session = Fixture.bucket(id: "five_hour", percent: 30, resetsAt: t1.addingTimeInterval(3600), kind: .session)
        let weekly = Fixture.bucket(id: "seven_day", percent: 82, resetsAt: t1.addingTimeInterval(86_400), kind: .weekly)
        let retained = Fixture.snapshot(id: "claude", buckets: [session, weekly], state: .notRunning, at: t0)

        let content = FloatingMiniLayout.content(for: retained)
        XCTAssertEqual(content.rows.map(\.id), ["seven_day"])
        XCTAssertEqual(content.retainedAt, t0)
        XCTAssertNil(
            FloatingMiniLayout.pace(for: weekly, in: content, now: t1),
            "the row bucket has no pace marker either, under the same content"
        )
    }

    func testAWindowlessRetainedPayAsYouGoAccountHasNoHeroToStamp() throws {
        // Documents the current, expected-for-P1 state: `detailHero` depends only on
        // `buckets`, and a windowless retained account has none, so `content(for:)`
        // takes the early-return branch and never reaches the line that would set
        // `retainedAt`. The spec's shared-file rule assigns the fix for this branch
        // (cost-only content instead of "haven't used") to P4, in a separate branch
        // with its own test — this is not a P1 finding, it is what P1 leaves behind
        // for P4 to pick up.
        let good = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [], weekCost: 31.7, at: t0)
        let failed = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .error, stateMessage: "500", at: t1)
        let merged = AppState.retainingLastGoodServices(
            previous: poll([good], at: t0), next: poll([failed], at: t1), stored: [:]
        )
        let retainedPayAsYouGo = try XCTUnwrap(merged.services.first)
        XCTAssertTrue(retainedPayAsYouGo.isRetained)
        XCTAssertEqual(retainedPayAsYouGo.spendHeadline, 31.7)

        let content = FloatingMiniLayout.content(for: retainedPayAsYouGo)
        XCTAssertNil(content.hero)
        XCTAssertNil(content.retainedAt, "the windowless branch carries the state message instead of a stamp")
        // With P4 merged (spec § UI, floating panel): a provider that is not `.ok`
        // shows its own message, never "haven't used" — here the fixture's "500".
        XCTAssertEqual(content.emptyText, "500")
        XCTAssertNil(content.weekCost, "a failed poll shows the failure, not the spend")
    }
}
