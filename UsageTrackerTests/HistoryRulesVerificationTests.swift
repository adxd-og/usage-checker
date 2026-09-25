import XCTest
@testable import Omelette

/// Independent verification of `HistoryRules` against the liquid-glass spec's History
/// screens and session ruling S1 / review finding F1 (docs/superpowers/plans/
/// 2026-09-25-3.0-P5-history.md). Writes its own fixtures; does not reuse
/// `HistoryRulesTests`.
final class HistoryRulesVerificationTests: XCTestCase {
    /// 2026-09-06 15:20 UTC — a Sunday, per CLAUDE.md. Mid-afternoon so a "24h rolling"
    /// window and a calendar-day window disagree, which is the point.
    private let now = Date(timeIntervalSince1970: 1_788_708_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func row(_ offset: Int, cost: Double, tokens: Int = 500, turns: Int = 3) -> CLIDailySummary {
        CLIDailySummary(
            day: day(offset), totalCost: cost, totalTokens: tokens,
            tokens: TokenBreakdown(input: tokens), turns: turns, byFamily: [:]
        )
    }

    // MARK: - windowStart / dayCount, ruling S1

    func testOneYearIs365DaysAndMatchesActivityCardRule() {
        XCTAssertEqual(HistoryRules.calendarDays(.oneYear), 365)
        let cutoffs = ActivityCardRule.cutoffs(now: now, calendar: calendar)
        XCTAssertEqual(HistoryRules.windowStart(range: .oneYear, now: now, calendar: calendar), cutoffs.year)
        XCTAssertEqual(HistoryRules.dayCount(range: .oneYear, now: now, calendar: calendar), 365)
    }

    func testDayCountsMatchTheDecisionsTable() {
        XCTAssertEqual(HistoryRules.dayCount(range: .oneDay, now: now, calendar: calendar), 2, "24h")
        XCTAssertEqual(HistoryRules.dayCount(range: .sevenDays, now: now, calendar: calendar), 7, "7d")
        XCTAssertEqual(HistoryRules.dayCount(range: .thirtyDays, now: now, calendar: calendar), 30, "30d")
        XCTAssertEqual(HistoryRules.dayCount(range: .ninetyDays, now: now, calendar: calendar), 90, "90d")
        XCTAssertEqual(HistoryRules.dayCount(range: .oneYear, now: now, calendar: calendar), 365, "1y")
    }

    func test24hIsARollingLocalDayNotACalendarCut() {
        // now is 15:00 on day(0); now - 24h is 15:00 on day(-1); the local day that
        // falls in is day(-1) itself, not day(-2) and not day(0).
        let start = HistoryRules.windowStart(range: .oneDay, now: now, calendar: calendar)
        XCTAssertEqual(start, day(-1))
    }

    // MARK: - days(daily:range:now:calendar:) boundaries

    func testTheDayBeforeTheWindowIsExcludedAtSevenDays() {
        let days = HistoryRules.days(
            daily: [row(-7, cost: 999)], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertTrue(days.isEmpty, "the eighth day back is outside a 7-day window")
    }

    func testTheFirstDayOfTheWindowIsIncluded() {
        let days = HistoryRules.days(
            daily: [row(-6, cost: 12)], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(days.map(\.day), [day(-6)])
    }

    func testTodayIsIncluded() {
        let days = HistoryRules.days(
            daily: [row(0, cost: 5)], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(days.map(\.day), [day(0)])
    }

    func testATomorrowStampedRowIsExcludedFromTheChart() {
        // A clock set back after a row was written can leave a day-start in the future.
        let days = HistoryRules.days(
            daily: [row(0, cost: 5), row(1, cost: 9_999)], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(days.map(\.day), [day(0)], "tomorrow's row must not appear")
    }

    // MARK: - summary: total equals the sum of the bars (ruling S1)

    func testRangeTotalEqualsTheSumOfTheBarsAtEveryBoundary() {
        let rows = [row(-7, cost: 40), row(-6, cost: 1), row(-3, cost: 2.5), row(0, cost: 3), row(1, cost: 1_000)]
        let days = HistoryRules.days(daily: rows, range: .sevenDays, now: now, calendar: calendar)
        let summary = HistoryRules.summary(days, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.cost).reduce(0, +), summary.cost, accuracy: 0.0001)
        XCTAssertEqual(summary.cost, 6.5, accuracy: 0.0001, "day -7 and day +1 must not count")
        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.dayCount, 7)
    }

    func testASummaryOverEmptyDaysIsZeroNotCrashing() {
        let days = HistoryRules.days(daily: [], range: .ninetyDays, now: now, calendar: calendar)
        let summary = HistoryRules.summary(days, range: .ninetyDays, now: now, calendar: calendar)
        XCTAssertEqual(summary.cost, 0)
        XCTAssertEqual(summary.activeDays, 0)
        XCTAssertEqual(summary.dayCount, 90)
    }

    // MARK: - showsModePicker (spec § Decisions, "Calendar in Tokens mode")

    func testCostTokensSwitchOnlyShowsOverAChartOfACostLog() {
        XCTAssertTrue(HistoryRules.showsModePicker(view: .chart, showsQuota: false))
        XCTAssertFalse(HistoryRules.showsModePicker(view: .calendar, showsQuota: false), "calendar is cost only")
        XCTAssertFalse(HistoryRules.showsModePicker(view: .chart, showsQuota: true), "quota-only has one unit")
        XCTAssertFalse(HistoryRules.showsModePicker(view: .calendar, showsQuota: true))
    }

    // MARK: - quotaChart / quotaDomain, review finding F1

    func testQuotaChartDomainEqualsQuotaDomainForTheSameNow() {
        for range: TimeRange in [.oneDay, .sevenDays, .thirtyDays, .ninetyDays, .oneYear] {
            let chart = HistoryRules.quotaChart(records: [], buckets: [], range: range, now: now, calendar: calendar)
            let domain = HistoryRules.quotaDomain(range: range, now: now, calendar: calendar)
            XCTAssertEqual(chart.domain, domain, "\(range)")
        }
    }

    func testQuotaDomainForACalendarRangeMatchesTheCostChartsWindowStart() {
        for range: TimeRange in [.sevenDays, .thirtyDays, .ninetyDays, .oneYear] {
            let domain = HistoryRules.quotaDomain(range: range, now: now, calendar: calendar)
            let windowStart = HistoryRules.windowStart(range: range, now: now, calendar: calendar)
            XCTAssertEqual(domain.lowerBound, windowStart, "\(range)")
            XCTAssertEqual(domain.upperBound, now, "\(range)")
        }
    }

    func testQuotaDomainAt24hIsRollingNotCalendarDay() {
        let domain = HistoryRules.quotaDomain(range: .oneDay, now: now, calendar: calendar)
        XCTAssertEqual(domain.lowerBound, now.addingTimeInterval(-TimeRange.oneDay.seconds))
        XCTAssertEqual(domain.upperBound, now)
    }

    func testQuotaSeriesOnlyKeepsPointsInsideTheDomain() {
        let bucket = QuotaBucketInfo(id: "five_hour", label: "5h", isCore: true, isLive: true)
        let records = Fixture.quotaHistory(points: [
            (at: day(-8), percents: ["five_hour": 91]),   // before the 7d window
            (at: day(-6), percents: ["five_hour": 40]),   // the window's first day
            (at: now, percents: ["five_hour": 77]),       // now
        ])
        let series = HistoryRules.quotaSeries(
            records: records, buckets: [bucket], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(series.count, 1)
        let domain = HistoryRules.quotaDomain(range: .sevenDays, now: now, calendar: calendar)
        for point in series[0].points {
            XCTAssertTrue(point.time >= domain.lowerBound && point.time <= domain.upperBound)
        }
        XCTAssertEqual(Set(series[0].points.map(\.percent)), [40, 77], "the day -8 reading must not appear")
    }

    func testQuotaSeriesOmitsAWindowWithNoReadingInRange() {
        let buckets = [
            QuotaBucketInfo(id: "five_hour", label: "5h", isCore: true, isLive: true),
            QuotaBucketInfo(id: "seven_day", label: "7d", isCore: true, isLive: true),
        ]
        let records = Fixture.quotaHistory(points: [(at: now, percents: ["five_hour": 50])])
        let series = HistoryRules.quotaSeries(
            records: records, buckets: buckets, range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(series.map(\.bucket.id), ["five_hour"], "seven_day has no reading and must be left out")
    }

    // MARK: - quotaSeriesToken wraps

    func testQuotaSeriesTokenWrapsAndNeverGoesNegativeIndex() {
        let count = HistoryRules.quotaSeriesTokens.count
        XCTAssertEqual(HistoryRules.quotaSeriesToken(index: 0), HistoryRules.quotaSeriesTokens[0])
        XCTAssertEqual(HistoryRules.quotaSeriesToken(index: count), HistoryRules.quotaSeriesTokens[0], "a seventh window restarts the colours")
        XCTAssertEqual(HistoryRules.quotaSeriesToken(index: -1), HistoryRules.quotaSeriesTokens[count - 1])
    }

    // MARK: - TimeRange.oneYear (Task 1) and the History range picker

    func testOneYearsRawValueIsTheStorageContractString() {
        XCTAssertEqual(TimeRange.oneYear.rawValue, "1y")
        XCTAssertEqual(TimeRange.oneYear.displayName, "1y")
        XCTAssertEqual(TimeRange.oneYear.seconds, 365 * 24 * 3600)
    }

    func testRangePickerOffersHistorysFiveRangesInTheMockupsOrder() {
        let items = RangePicker.items(for: HistoryRules.ranges)
        XCTAssertEqual(items.map(\.id), ["24h", "7d", "30d", "90d", "1y"])
        XCTAssertEqual(items.map(\.title), ["24h", "7d", "30d", "90d", "1y"])
    }

    func testEveryQuotaAxisStrideCaseIsHandled() {
        // Exercises every `TimeRange` case through `quotaAxisStride`, pinning the
        // stride so a future case added to the enum without a matching arm here (or
        // there) is caught by a wrong assertion rather than a missing `default:`.
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .fiveHours), HistoryAxisStride(component: .hour, count: 1))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .oneDay), HistoryAxisStride(component: .hour, count: 4))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .sevenDays), HistoryAxisStride(component: .day, count: 1))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .thirtyDays), HistoryAxisStride(component: .day, count: 4))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .ninetyDays), HistoryAxisStride(component: .day, count: 12))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .oneYear), HistoryAxisStride(component: .month, count: 1))
    }
}
