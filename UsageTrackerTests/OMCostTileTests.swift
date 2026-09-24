import XCTest
@testable import Omelette

/// Issue #6: the All-tab cost tile said "Last 7 days" and nothing else, so a day with
/// no spend read as the app having quietly switched itself to a weekly figure. Today
/// leads; the week keeps its number on the line below.
final class OMCostTileTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private var services: [ServiceSnapshot] {
        [
            Fixture.snapshot(id: "claude", displayName: "Claude", weekCost: 408.03),
            Fixture.snapshot(id: "codex", displayName: "Codex", weekCost: 1.64),
        ]
    }

    // MARK: - Title

    func testTheTitleIsTodayWhenTodayIsKnown() {
        XCTAssertEqual(OMCostTile.title(todayKnown: true), "Today")
    }

    func testTheTitleFallsBackToTheWeekWhenNoLogHasBeenRead() {
        XCTAssertEqual(OMCostTile.title(todayKnown: false), "Last 7 days")
    }

    // MARK: - Today's total

    func testTodayIsUnknownWhenNoProviderHasACostLog() {
        XCTAssertNil(OMCostTile.todayTotal(services, today: [:]))
    }

    func testTodaySumsOnlyTheProvidersOnScreen() {
        let today = ["claude": 12.5, "codex": 1.25, "grok": 99]
        XCTAssertEqual(OMCostTile.todayTotal(services, today: today) ?? -1, 13.75, accuracy: 0.0001)
    }

    /// The reporter's own case: a log that exists and says nothing was spent today is
    /// an answer, not a missing number.
    func testAProviderThatSpentNothingTodayIsStillKnown() {
        let today = ["claude": 0.0]
        XCTAssertEqual(OMCostTile.todayTotal(services, today: today) ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(OMCostTile.title(todayKnown: OMCostTile.todayTotal(services, today: today) != nil), "Today")
    }

    // MARK: - Secondary line

    func testTheSecondaryLineLeadsWithTheWeekTotalThenTheBreakdown() {
        XCTAssertEqual(
            OMCostTile.secondary(services: services, today: ["claude": 0.0], locale: us),
            "Last 7 days $409.67 · Claude $408.03 · Codex $1.64"
        )
    }

    /// Without today's number the tile keeps the shape it has always had: the week is
    /// the headline, so repeating it underneath would say nothing.
    func testWithoutTodayTheSecondaryLineIsJustTheBreakdown() {
        XCTAssertEqual(
            OMCostTile.secondary(services: services, today: [:], locale: us),
            "Claude $408.03 · Codex $1.64"
        )
    }

    func testAProviderWithoutALocalCostLogStaysOutOfTheBreakdown() {
        let withAntigravity = services + [Fixture.snapshot(id: "antigravity", displayName: "Antigravity", weekCost: nil)]
        XCTAssertEqual(
            OMCostTile.secondary(services: withAntigravity, today: ["claude": 4], locale: us),
            "Last 7 days $409.67 · Claude $408.03 · Codex $1.64"
        )
    }

    func testTheWeekTotalStillIgnoresProvidersWithoutASpend() {
        XCTAssertEqual(OMCostTile.total(services), 409.67, accuracy: 0.0001)
    }

    // MARK: - API-equivalent caption

    /// A provider that reported a window of its own is on a subscription, where local
    /// dollars are what the same tokens would cost through the API.
    private var subscription: ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)],
            weekCost: 408.03
        )
    }

    func testASubscriptionInTheTileGetsTheCaption() {
        XCTAssertEqual(OMCostTile.caption(services: [subscription]), CostCopy.apiEquivalent)
        XCTAssertEqual(
            OMCostTile.caption(services: [subscription] + services.filter { $0.id == "codex" }),
            CostCopy.apiEquivalent,
            "one subscription among the dollars is enough"
        )
    }

    /// `services` above report no window: pay-as-you-go by `CostCopy.isPayAsYouGo`,
    /// whose dollars are close to the bill.
    func testAnAllPayAsYouGoTileHasNoCaption() {
        XCTAssertNil(OMCostTile.caption(services: services))
    }

    func testOnlyProvidersWithDollarsInTheTileCount() {
        let quiet = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "codex_session", kind: .session)],
            weekCost: 0
        )
        let payg = Fixture.snapshot(id: "claude", displayName: "Claude", weekCost: 12)
        XCTAssertNil(OMCostTile.caption(services: [payg, quiet]), "a subscription with nothing spent does not caption someone else's dollars")
        XCTAssertEqual(
            OMCostTile.caption(services: [payg, quiet], today: ["codex": 1.5]),
            CostCopy.apiEquivalent,
            "today's dollars are dollars in the tile too"
        )
    }

    func testVoiceOverHearsTheCaptionToo() {
        XCTAssertEqual(
            OMCostTile.accessibilityText(services: [subscription], today: ["claude": 12.5], locale: us),
            "Today $12.50. API-equivalent cost of your CLI usage — not what your subscription bills."
        )
        XCTAssertEqual(
            OMCostTile.accessibilityText(services: services, today: ["claude": 12.5], locale: us),
            "Today $12.50"
        )
    }
}
