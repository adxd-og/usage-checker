import XCTest
@testable import Omelette

/// Independent verification of `HistoryCalendarRules` against liquid-glass spec §
/// Screens "History · Calendar" and review finding F2 (every calendar filter ends at
/// the start of tomorrow, exclusive). Own fixtures, not the executor's.
final class HistoryCalendarRulesVerificationTests: XCTestCase {
    /// 2026-09-06 15:00 UTC — a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_708_000)

    /// `Calendar`'s `firstWeekday` is not derived from `locale` unless the calendar
    /// itself came from one; a bare `Calendar(identifier:)` defaults to 1 (Sunday)
    /// whatever `locale` is set to afterward. Pinned explicitly so the `weeks()` math
    /// below is read against a known first weekday, not an accident of init order.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = 1
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func row(_ offset: Int, cost: Double) -> CLIDailySummary {
        CLIDailySummary(
            day: day(offset), totalCost: cost, totalTokens: 100,
            tokens: TokenBreakdown(input: 100), turns: 1, byFamily: [:]
        )
    }

    // MARK: - windowEnd (F2)

    func testWindowEndIsTheStartOfTomorrow() {
        XCTAssertEqual(HistoryCalendarRules.windowEnd(now: now, calendar: calendar), day(1))
    }

    // MARK: - costRows: "$10 today / $1,000 tomorrow → today keeps the maximum"

    func testATomorrowStampedCostRowDoesNotRaiseTheRangesScale() {
        let rows = [row(0, cost: 10), row(1, cost: 1_000)]
        let kept = HistoryCalendarRules.costRows(rows, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(kept.map(\.day), [day(0)], "tomorrow's row must be dropped, not just deprioritised")
        XCTAssertEqual(kept.map(\.totalCost).max(), 10, "the busiest day in range stays $10, never $1,000")
    }

    func testCostRowsExcludeTheDayBeforeTheRangeStarts() {
        let rows = [row(-8, cost: 500), row(-6, cost: 4)]
        let kept = HistoryCalendarRules.costRows(rows, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(kept.map(\.day), [day(-6)])
    }

    func testCostRowsIncludeTodayAndTheRangesFirstDay() {
        let rows = [row(-6, cost: 1), row(0, cost: 2)]
        let kept = HistoryCalendarRules.costRows(rows, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(Set(kept.map(\.day)), [day(-6), day(0)])
    }

    // MARK: - quotaRecords / quotaSummary: "today 50% / tomorrow 100% → 0 of 1 day at limit"

    func testATomorrowStampedReadingIsExcludedFromTheDaysAtLimitCount() {
        let buckets = [QuotaBucketInfo(id: "five_hour", label: "5h", isCore: true, isLive: true)]
        let records = Fixture.quotaHistory(points: [
            (at: day(0).addingTimeInterval(3600), percents: ["five_hour": 50]),   // today, below threshold
            (at: day(1).addingTimeInterval(3600), percents: ["five_hour": 100]),  // tomorrow, at capacity
        ])
        let kept = HistoryCalendarRules.quotaRecords(records, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(kept.count, 1, "tomorrow's reading must not be in range")

        let summary = HistoryCalendarRules.quotaSummary(
            records: records, buckets: buckets, range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.daysAtLimit, 0)
        XCTAssertEqual(summary.daysObserved, 1)
        XCTAssertEqual(HistoryCopy.daysAtLimit(summary.daysAtLimit, of: summary.daysObserved), "0 of 1 day at limit")
    }

    func testAReadingExactlyAtWindowEndIsExcludedExclusiveBound() {
        let boundary = HistoryCalendarRules.windowEnd(now: now, calendar: calendar)
        let records = Fixture.quotaHistory(points: [(at: boundary, percents: ["five_hour": 99])])
        let kept = HistoryCalendarRules.quotaRecords(records, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertTrue(kept.isEmpty, "windowEnd itself is the excluded bound")
    }

    func testAReadingJustBeforeWindowEndIsIncluded() {
        let boundary = HistoryCalendarRules.windowEnd(now: now, calendar: calendar)
        let records = Fixture.quotaHistory(points: [(at: boundary.addingTimeInterval(-1), percents: ["five_hour": 99])])
        let kept = HistoryCalendarRules.quotaRecords(records, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(kept.count, 1)
    }

    func testQuotaSummaryOnlyCountsCoreBuckets() {
        let buckets = [
            QuotaBucketInfo(id: "five_hour", label: "5h", isCore: true, isLive: true),
            QuotaBucketInfo(id: "promo", label: "Promo", isCore: false, isLive: true),
        ]
        let records = Fixture.quotaHistory(points: [
            (at: day(0), percents: ["five_hour": 20, "promo": 100]),
        ])
        let summary = HistoryCalendarRules.quotaSummary(
            records: records, buckets: buckets, range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.daysAtLimit, 0, "the promo window's 100% must not count toward the limit")
    }

    // MARK: - costLevel / levelOpacity ramp (four steps)

    func testCostLevelStepsAtEachQuarter() {
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0), 0)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.01), 1)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.25), 1)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.26), 2)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.5), 2)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.51), 3)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 1.0), 4)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 1.5), 4, "clamped, never a fifth step")
    }

    func testLevelOpacityMatchesTheMockupsColorMixSteps() {
        XCTAssertEqual(HistoryCalendarRules.levelOpacity(0), 0)
        XCTAssertEqual(HistoryCalendarRules.levelOpacity(1), 0.28)
        XCTAssertEqual(HistoryCalendarRules.levelOpacity(2), 0.50)
        XCTAssertEqual(HistoryCalendarRules.levelOpacity(3), 0.75)
        XCTAssertEqual(HistoryCalendarRules.levelOpacity(4), 1)
    }

    // MARK: - weeks(from:now:calendar:)

    func testWeeksCoversFromTheRangesFirstWeekToThisWeek() {
        // 7d's window starts day(-6): 2026-08-31 (Monday), which on a Sunday-first
        // calendar sits in the PRIOR week (Aug 30 – Sep 5). now (day 0) is 2026-09-06,
        // a Sunday, which starts a new week. Two columns, not one.
        let start = HistoryRules.windowStart(range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(HistoryCalendarRules.weeks(from: start, now: now, calendar: calendar), 2)
    }

    func testAYearIsAboutFiftyThreeWeeks() {
        let start = HistoryRules.windowStart(range: .oneYear, now: now, calendar: calendar)
        let weeks = HistoryCalendarRules.weeks(from: start, now: now, calendar: calendar)
        XCTAssertTrue((52...54).contains(weeks), "got \(weeks)")
    }
}
