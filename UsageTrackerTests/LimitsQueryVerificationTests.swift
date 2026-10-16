import XCTest
@testable import Omelette

/// What a load answered, at the edges: limit-analytics spec (2026-10-16) § The tab (the
/// tab shows the current window) and § Accounts without percent windows (the mode table
/// and its periods: a subscription's window, pay as you go's last 7 days against the
/// weekly budget, a spend limit's calendar month against its limit).
final class LimitsQueryVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday; a whole minute.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    /// 2026-10-01 00:00 UTC.
    private let october = Date(timeIntervalSince1970: 1_790_812_800)

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { calendar("UTC") }

    /// A Claude week whose window began `offset` seconds after 2026-09-01 12:00 UTC.
    private func weekQuery(offset: TimeInterval) -> LimitsQuery {
        let service = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day + offset), kind: .weekly),
        ])
        return LimitsRules.query(
            serviceID: "claude", service: service, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        )
    }

    private func payAsYouGo(id: String = "claude", budget: Double, extraBuckets: [UsageBucket] = []) -> LimitsQuery {
        let service = Fixture.snapshot(id: id, plan: nil, buckets: extraBuckets, weekCost: 0)
        return LimitsRules.query(
            serviceID: id, service: service, kind: .weekly, weeklyBudgetUSD: budget, now: now, calendar: utc
        )
    }

    private func spendLimit(
        at time: Date, zone: String = "UTC", limit: Double = 2_000, used: Double = 1_240
    ) -> LimitsQuery {
        let service = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: limit, usedCredits: used, utilization: 62),
            weekCost: 300
        )
        return LimitsRules.query(
            serviceID: "claude", service: service, kind: .weekly, weeklyBudgetUSD: 0,
            now: time, calendar: calendar(zone)
        )
    }

    // MARK: - A window start within half a minute

    func testAWindowStartWithinHalfAMinuteEitherSideOfAMinuteIsOneWindow() {
        let exact = weekQuery(offset: 0)
        for offset in [-29.9, -20, -1, -0.001, 0.001, 1, 20, 29.9] {
            XCTAssertEqual(weekQuery(offset: offset), exact, "a reset reported \(offset) s off the minute")
        }
    }

    func testAWindowStartPastHalfAMinuteIsTheNextMinutesWindow() {
        XCTAssertEqual(weekQuery(offset: 31), weekQuery(offset: 60))
        XCTAssertNotEqual(weekQuery(offset: 31), weekQuery(offset: 0))
        XCTAssertEqual(weekQuery(offset: -31), weekQuery(offset: -60))
        XCTAssertNotEqual(weekQuery(offset: -31), weekQuery(offset: 0))
    }

    func testTheMinuteIsAWholeMinuteNoMoreThanHalfAMinuteAway() {
        for step in 0..<400 {
            let date = now.addingTimeInterval(Double(step) * 1.37 - 250)
            let minute = LimitsRules.toMinute(date)
            XCTAssertEqual(minute.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(minute.timeIntervalSince(date)), 30 + 1e-6)
            XCTAssertEqual(LimitsRules.toMinute(minute), minute, "a minute stays itself")
        }
    }

    // MARK: - A budget changing, or set to 0

    func testABudgetOfZeroOrLessIsNoBudget() {
        XCTAssertEqual(payAsYouGo(budget: 0), payAsYouGo(budget: -5))
        XCTAssertEqual(payAsYouGo(budget: 0).measure, .payAsYouGo(budget: nil))
    }

    func testASetBudgetIsPartOfTheQueryToTheLastCent() {
        XCTAssertEqual(payAsYouGo(budget: 500).measure, .payAsYouGo(budget: 500))
        XCTAssertNotEqual(payAsYouGo(budget: 500), payAsYouGo(budget: 0))
        XCTAssertNotEqual(payAsYouGo(budget: 500), payAsYouGo(budget: 500.01))
        XCTAssertNotEqual(payAsYouGo(budget: 0.01), payAsYouGo(budget: 0))
    }

    func testClearingABudgetReturnsToTheQueryBeforeItWasSet() {
        let before = payAsYouGo(budget: 0)
        XCTAssertNotEqual(payAsYouGo(budget: 500), before)
        XCTAssertEqual(payAsYouGo(budget: 0), before)
    }

    func testCodexHasNoBudgetSoItsQueryIgnoresTheClaudeSetting() {
        XCTAssertEqual(payAsYouGo(id: "codex", budget: 500), payAsYouGo(id: "codex", budget: 0))
        XCTAssertEqual(payAsYouGo(id: "codex", budget: 500).measure, .payAsYouGo(budget: nil))
        XCTAssertNotEqual(payAsYouGo(id: "codex", budget: 0), payAsYouGo(id: "claude", budget: 0), "the provider is in the query")
    }

    func testTheSyntheticBudgetBucketDoesNotMakeAWindow() {
        let synthetic = Fixture.bucket(id: "claude_weekly_budget", label: "Weekly budget", percent: 80,
                                       resetsAt: now.addingTimeInterval(day), kind: .weekly)
        XCTAssertEqual(payAsYouGo(budget: 500, extraBuckets: [synthetic]), payAsYouGo(budget: 500))
    }

    func testTheLastSevenDaysRollOnWithoutChangingTheQuery() {
        let service = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 0)
        let later = LimitsRules.query(
            serviceID: "claude", service: service, kind: .weekly, weeklyBudgetUSD: 500,
            now: now.addingTimeInterval(30 * day), calendar: utc
        )
        XCTAssertEqual(later, payAsYouGo(budget: 500))
    }

    // MARK: - Spend-limit month boundaries

    func testAMonthIsOneQueryFromItsFirstSecondToItsLast() {
        let firstSecond = spendLimit(at: Date(timeIntervalSince1970: 1_788_220_801))
        let lastSecond = spendLimit(at: october.addingTimeInterval(-1))
        XCTAssertEqual(firstSecond, lastSecond)
        XCTAssertEqual(
            lastSecond.measure,
            .spendLimit(monthStart: Date(timeIntervalSince1970: 1_788_220_800), limit: 2_000)
        )
    }

    func testTheNextMonthIsANewQueryFromItsFirstSecond() {
        let september = spendLimit(at: october.addingTimeInterval(-1))
        let nextMonth = spendLimit(at: october.addingTimeInterval(1))
        XCTAssertNotEqual(september, nextMonth)
        XCTAssertEqual(nextMonth.measure, .spendLimit(monthStart: october, limit: 2_000))
    }

    func testTheMonthIsTheCalendarsNotUTCs() {
        // 2026-10-01 03:00 UTC is still 30 September in Los Angeles (UTC-7).
        let time = october.addingTimeInterval(3 * 3_600)
        XCTAssertEqual(
            spendLimit(at: time, zone: "America/Los_Angeles").measure,
            .spendLimit(monthStart: Date(timeIntervalSince1970: 1_788_220_800 + 7 * 3_600), limit: 2_000)
        )
        XCTAssertEqual(spendLimit(at: time, zone: "UTC").measure, .spendLimit(monthStart: october, limit: 2_000))
        XCTAssertNotEqual(spendLimit(at: time, zone: "America/Los_Angeles"), spendLimit(at: time, zone: "UTC"))
    }

    func testTheLimitIsPartOfTheQueryAndTheCreditsAreNot() {
        XCTAssertNotEqual(spendLimit(at: now, limit: 2_000), spendLimit(at: now, limit: 2_000.5))
        XCTAssertEqual(spendLimit(at: now, used: 0), spendLimit(at: now, used: 1_999.99))
    }

    func testASpendLimitOfZeroOrSwitchedOffIsPayAsYouGoNotASpendLimit() {
        XCTAssertEqual(spendLimit(at: now, limit: 0).measure, .payAsYouGo(budget: nil))
        let off = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: 2_000, usedCredits: 0, utilization: 0),
            weekCost: 0
        )
        XCTAssertEqual(
            LimitsRules.query(serviceID: "claude", service: off, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc).measure,
            .payAsYouGo(budget: nil)
        )
    }

    func testTheKindIsPartOfTheQuery() {
        let service = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", percent: 9, resetsAt: now.addingTimeInterval(3_600), kind: .session),
            Fixture.bucket(id: "seven_day", percent: 40, resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
        let session = LimitsRules.query(serviceID: "claude", service: service, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        let week = LimitsRules.query(serviceID: "claude", service: service, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc)
        XCTAssertNotEqual(session, week)
        XCTAssertEqual(session.kind, .session)
        XCTAssertEqual(week.kind, .weekly)
    }

    func testTheLoadKeyChangesWithTheQueryAndWithTheIngestStamp() {
        let query = weekQuery(offset: 0)
        let first = LimitsLoadKey(query: query, ingestedAt: now)
        XCTAssertEqual(first, LimitsLoadKey(query: query, ingestedAt: now))
        XCTAssertNotEqual(first, LimitsLoadKey(query: query, ingestedAt: now.addingTimeInterval(60)))
        XCTAssertNotEqual(first, LimitsLoadKey(query: weekQuery(offset: 60), ingestedAt: now))
        XCTAssertNotEqual(first, LimitsLoadKey(query: query, ingestedAt: nil))
    }
}
