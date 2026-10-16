import XCTest
@testable import Omelette

/// What a limit share answered: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Packages 2 (the tab loads the selected provider's current window) and § Accounts
/// without percent windows (the mode table and its periods). A share answers one
/// provider, one window kind, and one window or period measured against one budget or
/// limit. The next ingest's share of the same window answers the same query; a reset, a
/// mode change or a new budget asks a new one.
final class LimitsQueryTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    /// 2026-09-01 and 2026-10-01, 00:00 UTC.
    private let september = Date(timeIntervalSince1970: 1_788_220_800)
    private let october = Date(timeIntervalSince1970: 1_790_812_800)

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    private func week(start: Date, end: Date, live: Double) -> LimitsQuery {
        LimitsRules.query(serviceID: "claude", kind: .weekly, request: LimitShareRequest(
            mode: .subscription, period: LimitWindow(start: start, end: end),
            bucketID: "seven_day", livePercent: live
        ))
    }

    private func payAsYouGo(budget: Double?, end: Date) -> LimitsQuery {
        LimitsRules.query(serviceID: "claude", kind: .weekly, request: LimitShareRequest(
            mode: .payAsYouGo(weeklyBudget: budget),
            period: LimitWindow(start: end.addingTimeInterval(-7 * day), end: end),
            bucketID: nil, livePercent: nil
        ))
    }

    private func spendLimit(month: Date, limit: Double, used: Double) -> LimitsQuery {
        LimitsRules.query(serviceID: "claude", kind: .weekly, request: LimitShareRequest(
            mode: .spendLimit(monthlyLimit: limit, usedCredits: used),
            period: LimitWindow(start: month, end: month.addingTimeInterval(5 * day)),
            bucketID: nil, livePercent: nil
        ))
    }

    func testTheNextIngestsShareAnswersTheSameQuery() {
        let start = now.addingTimeInterval(-5 * day)
        let first = week(start: start, end: now, live: 40)
        XCTAssertEqual(first, week(start: start, end: now.addingTimeInterval(60), live: 41),
                       "a later end and a higher percent are the same window")
        XCTAssertEqual(first.measure, .window(start: start))
    }

    func testAResetStartsANewWindowAndANewQuery() {
        XCTAssertNotEqual(
            week(start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day), live: 70),
            week(start: now.addingTimeInterval(-5 * day), end: now, live: 3)
        )
    }

    func testAWindowIsKnownByItsStartToTheMinute() {
        // A reset reported at 11:59:59 rather than 12:00:00 is the same window.
        let start = now.addingTimeInterval(-5 * day)
        XCTAssertEqual(
            week(start: start.addingTimeInterval(-1), end: now, live: 40),
            week(start: start, end: now, live: 40)
        )
        XCTAssertEqual(LimitsRules.toMinute(start.addingTimeInterval(-1)), start)
    }

    func testAModeOrBudgetChangeIsANewQuery() {
        XCTAssertNotEqual(payAsYouGo(budget: 500, end: now), payAsYouGo(budget: 1_000, end: now))
        XCTAssertNotEqual(payAsYouGo(budget: nil, end: now), payAsYouGo(budget: 500, end: now))
        XCTAssertNotEqual(payAsYouGo(budget: nil, end: now), week(start: now.addingTimeInterval(-5 * day), end: now, live: 0))
        XCTAssertEqual(payAsYouGo(budget: 500, end: now), payAsYouGo(budget: 500, end: now.addingTimeInterval(60)),
                       "the last 7 days roll forward and stay one period")
    }

    func testASpendLimitIsKnownByItsMonthAndLimitNotItsCredits() {
        XCTAssertEqual(spendLimit(month: september, limit: 2_000, used: 1_240),
                       spendLimit(month: september, limit: 2_000, used: 1_300),
                       "the server's credits move with every poll; the next ingest brings them")
        XCTAssertNotEqual(spendLimit(month: september, limit: 2_000, used: 1_240),
                          spendLimit(month: september, limit: 3_000, used: 1_240))
        XCTAssertNotEqual(spendLimit(month: september, limit: 2_000, used: 1_240),
                          spendLimit(month: october, limit: 2_000, used: 0))
    }

    func testNothingToMeasureHasNoMeasure() {
        XCTAssertNil(LimitsRules.query(serviceID: "claude", kind: .weekly, request: nil).measure)
        let signedOut = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn)
        XCTAssertNil(LimitsRules.query(
            serviceID: "claude", service: signedOut, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ).measure)
    }

    func testALoadAnswersTheQueryItsSnapshotAsks() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claudeMax, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let load = DashboardState.LimitShareLoad(
            serviceID: "claude", kind: .weekly, request: request,
            share: Fixture.limitShare(window: request.period)
        )
        XCTAssertEqual(load.query, LimitsRules.query(
            serviceID: "claude", service: claudeMax, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        XCTAssertEqual(load.query, LimitsRules.query(
            serviceID: "claude", service: claudeMax, kind: .weekly, weeklyBudgetUSD: 0,
            now: now.addingTimeInterval(hour), calendar: utc
        ), "an hour on, the snapshot still asks for the same week")
    }
}
