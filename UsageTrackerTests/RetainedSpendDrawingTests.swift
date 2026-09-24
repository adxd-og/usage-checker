import XCTest
@testable import Omelette

/// Where a retained pay-as-you-go spend is drawn and what it is called. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "a
/// spend-only retained service dims like any other." The views read `spendHeadline`
/// and `isRetained`; the words they show are these rules.
final class RetainedSpendDrawingTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    private var readAt: Date { moment(day: 5, hour: 14, minute: 5) }
    private var now: Date { moment(day: 5, hour: 17, minute: 40) }

    /// The retained account exactly as the app builds it: one good poll, then a failed
    /// one, through the real retention rule.
    private func retainedPayAsYouGo() throws -> ServiceSnapshot {
        let good = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Claude Enterprise",
                                    buckets: [], weekCost: 31.7, at: readAt)
        let failed = Fixture.snapshot(id: "claude", displayName: "Claude", plan: nil, buckets: [],
                                      state: .error, stateMessage: "500: internal error", at: now)
        let merged = AppState.retainingLastGoodServices(
            previous: UsageSnapshot(services: [good], fetchedAt: readAt, isStale: false, lastError: nil),
            next: UsageSnapshot(services: [failed], fetchedAt: now, isStale: false, lastError: nil),
            stored: [:]
        )
        return try XCTUnwrap(merged.services.first)
    }

    func testSpendLeadsForALiveAndForARetainedWindowlessAccount() throws {
        let live = Fixture.snapshot(id: "claude", buckets: [], weekCost: 31.7, at: now)
        XCTAssertEqual(live.spendHeadline, 31.7)
        let retained = try retainedPayAsYouGo()
        XCTAssertEqual(retained.spendHeadline, 31.7)
    }

    func testSpendDoesNotLeadWhenNothingWasCarriedOver() {
        // A signed-out Grok's own tile is its chip, as before.
        let grok = Fixture.snapshot(id: "grok", buckets: [], weekCost: 7.2, state: .notSignedIn, at: now)
        XCTAssertNil(grok.spendHeadline)
        XCTAssertNil(Fixture.snapshot(id: "claude", buckets: [], weekCost: nil, at: now).spendHeadline)
    }

    func testTheMenuBarLineGivesTheLastKnownSpendNotAPercentage() throws {
        let service = try retainedPayAsYouGo()
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: now, calendar: calendar, locale: locale),
            "Claude: last known spend $31.70 (as of 14:05) — Error"
        )
    }

    func testASpendLimitStillReadsAsAPercentage() {
        // Windowless, but an enabled spend limit is a number the account reported.
        var service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2),
            weekCost: 31.7, state: .error, at: readAt
        )
        service.isCarriedOver = true
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: now, calendar: calendar, locale: locale),
            "Claude: last known 78% (as of 14:05) — Error"
        )
    }

    func testTheCostPillSaysLastKnownOnlyWhenItIs() throws {
        let live = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [], weekCost: 31.7, at: now)
        XCTAssertEqual(
            MenuBarLabel.costPillText(for: live, weekCost: 31.7, now: now, calendar: calendar, locale: locale),
            "Claude spend 32 dollars this week"
        )
        let retained = try retainedPayAsYouGo()
        XCTAssertEqual(
            MenuBarLabel.costPillText(for: retained, weekCost: 31.7, now: now, calendar: calendar, locale: locale),
            "Claude: last known spend $31.70 (as of 14:05) — Error"
        )
    }

    func testTheTooltipNeverInventsAPercentage() throws {
        let service = try retainedPayAsYouGo()
        let text = StatusBarController.tooltipText(
            snapshot: UsageSnapshot(services: [service], fetchedAt: readAt, isStale: true, lastError: nil),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(text.contains("Claude: last known spend $31.70 (as of 14:05) — Error"), text)
        XCTAssertTrue(text.contains("  Last 7 days: $31.70"), text)
        XCTAssertFalse(text.contains("0%"), text)
    }
}
