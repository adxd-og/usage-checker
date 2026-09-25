import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "History · Chart": Cost and Tokens are the chart's two
/// units, and the chat list sits under the chart in both instead of being a third mode.
final class HistoryRulesModeTests: XCTestCase {
    func testTheChartOffersCostAndTokensOnly() {
        XCTAssertEqual(HistoryRules.chartModes, [.cost, .tokens])
    }

    func testARememberedSessionsModeReadsAsCost() {
        // 2.x's third mode is still in historyChartMode for anyone who left the tab on it.
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .sessions), .cost)
    }

    func testCostAndTokensStayWhatTheyWere() {
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .cost), .cost)
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .tokens), .tokens)
    }
}

/// Liquid-glass spec § Screens, "History · Chart": the range row is 24h 7d 30d 90d 1y.
/// 5h stays a `TimeRange` for Agents; History shows a day in its place.
final class HistoryRulesRangeTests: XCTestCase {
    func testHistoryOffersTheMockupsFiveRanges() {
        XCTAssertEqual(HistoryRules.ranges, [.oneDay, .sevenDays, .thirtyDays, .ninetyDays, .oneYear])
        XCTAssertEqual(RangePicker.items(for: HistoryRules.ranges).map(\.id), ["24h", "7d", "30d", "90d", "1y"])
    }

    func testAnOfferedRangeStaysWhatItIs() {
        for range in HistoryRules.ranges {
            XCTAssertEqual(HistoryRules.offeredRange(range), range)
        }
    }

    func testFiveHoursSetOnAgentsShowsAsADay() {
        XCTAssertEqual(HistoryRules.offeredRange(.fiveHours), .oneDay)
    }
}

/// Liquid-glass spec § Screens, "History · Chart", and session ruling S1: a day range is
/// that many calendar days ending today, cut the way `ActivityCardRule` cuts Overview's
/// "Last 7 days" and "Last 30 days", and the card's total is the sum of its bars. 24h
/// stays rolling.
final class HistoryRulesDaysTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func row(_ offset: Int, cost: Double) -> CLIDailySummary {
        CLIDailySummary(
            day: day(offset), totalCost: cost, totalTokens: 1_000,
            tokens: TokenBreakdown(input: 1_000), turns: 1, byFamily: [:]
        )
    }

    func testASevenDayRangeIsSevenLocalDaysIncludingToday() {
        XCTAssertEqual(HistoryRules.windowStart(range: .sevenDays, now: now, calendar: calendar), day(-6))
        XCTAssertEqual(HistoryRules.dayCount(range: .sevenDays, now: now, calendar: calendar), 7)
        let days = HistoryRules.days(
            daily: [row(-7, cost: 64), row(-6, cost: 2), row(0, cost: 1)],
            range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(days.map(\.day), [day(-6), day(0)], "the seventh day back is outside")
    }

    func testTheLongerRangesCutWhereActivityCardRuleCuts() {
        let cutoffs = ActivityCardRule.cutoffs(now: now, calendar: calendar)
        XCTAssertEqual(HistoryRules.windowStart(range: .thirtyDays, now: now, calendar: calendar), cutoffs.thirty)
        XCTAssertEqual(HistoryRules.windowStart(range: .ninetyDays, now: now, calendar: calendar), cutoffs.ninety)
        XCTAssertEqual(HistoryRules.windowStart(range: .oneYear, now: now, calendar: calendar), cutoffs.year)
    }

    func testEachDayRangeCountsItsDays() {
        XCTAssertEqual(HistoryRules.dayCount(range: .thirtyDays, now: now, calendar: calendar), 30)
        XCTAssertEqual(HistoryRules.dayCount(range: .ninetyDays, now: now, calendar: calendar), 90)
        XCTAssertEqual(HistoryRules.dayCount(range: .oneYear, now: now, calendar: calendar), 365)
    }

    func testTwentyFourHoursStaysRollingAcrossTheDaysItTouches() {
        XCTAssertNil(HistoryRules.calendarDays(.oneDay))
        XCTAssertEqual(HistoryRules.windowStart(range: .oneDay, now: now, calendar: calendar), day(-1))
        XCTAssertEqual(HistoryRules.dayCount(range: .oneDay, now: now, calendar: calendar), 2)
    }

    func testTheTotalIsTheSumOfTheBars() {
        let days = HistoryRules.days(
            daily: [row(-9, cost: 100), row(-6, cost: 2), row(-3, cost: 0), row(0, cost: 1.5)],
            range: .sevenDays, now: now, calendar: calendar
        )
        let summary = HistoryRules.summary(days, range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(summary.cost, days.map(\.cost).reduce(0, +))
        XCTAssertEqual(summary, HistoryRangeSummary(dayCount: 7, cost: 3.5, activeDays: 2))
    }

    func testRowsOnOneLocalDayAreOneBar() {
        // A row keyed by another zone's midnight folds onto the local day, as the
        // Calendar folds it (`GridCache.dailiesByDay`).
        let shifted = CLIDailySummary(
            day: day(-1).addingTimeInterval(3 * 3600), totalCost: 5, totalTokens: 10,
            tokens: TokenBreakdown(input: 10), turns: 2, byFamily: [:]
        )
        let days = HistoryRules.days(
            daily: [row(-1, cost: 1), shifted], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.cost, 6)
        XCTAssertEqual(days.first?.turns, 3)
    }

    func testTheChartSpansTheWholeRangeThroughTheEndOfToday() {
        XCTAssertEqual(HistoryRules.xDomain(range: .sevenDays, now: now, calendar: calendar), day(-6)...day(1))
    }
}

/// The chart's look (`Dashboard-History-Cost`, `-Tokens`), including a year of bars.
final class HistoryRulesChartLookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testOnlyTodaysBarIsInFullYolk() {
        XCTAssertEqual(HistoryRules.barOpacity(isToday: true), 1)
        XCTAssertEqual(HistoryRules.barOpacity(isToday: false), 0.5)
        XCTAssertTrue(HistoryRules.isToday(calendar.startOfDay(for: now), now: now, calendar: calendar))
        XCTAssertFalse(HistoryRules.isToday(now.addingTimeInterval(-86_400), now: now, calendar: calendar))
    }

    func testBarsCarryTheirFigureOnlyWhileThereIsRoomForIt() {
        XCTAssertTrue(HistoryRules.showsValueLabels(dayCount: 7))
        XCTAssertTrue(HistoryRules.showsValueLabels(dayCount: 10))
        XCTAssertFalse(HistoryRules.showsValueLabels(dayCount: 11))
        XCTAssertFalse(HistoryRules.showsValueLabels(dayCount: 30))
    }

    func testAboutEightDatesAlongTheAxis() {
        XCTAssertEqual(HistoryRules.axisStride(dayCount: 2), 1)
        XCTAssertEqual(HistoryRules.axisStride(dayCount: 7), 1)
        XCTAssertEqual(HistoryRules.axisStride(dayCount: 30), 3)
        XCTAssertEqual(HistoryRules.axisStride(dayCount: 365), 45)
    }

    func testThinBarsGetSmallCorners() {
        XCTAssertEqual(HistoryRules.barCornerRadius(dayCount: 7), 7)
        XCTAssertEqual(HistoryRules.barCornerRadius(dayCount: 31), 7)
        XCTAssertEqual(HistoryRules.barCornerRadius(dayCount: 90), 2)
    }
}

/// Liquid-glass spec § Screens, "History · quota-only provider" (`Dashboard-Quota-History`):
/// one coloured line per window on a fixed 0–100 % axis.
final class HistoryRulesQuotaTests: XCTestCase {
    func testTheLinesTakeTheMockupsColoursInTheProvidersOrder() {
        XCTAssertEqual(
            HistoryRules.quotaSeriesTokens,
            [.tokenCacheRead, .seriesSession, .seriesQuota, .seriesAllModels, .seriesPerModel, .tokenOutput]
        )
        XCTAssertEqual((0..<6).map(HistoryRules.quotaSeriesToken(index:)), HistoryRules.quotaSeriesTokens)
    }

    func testASeventhWindowStartsTheColoursAgain() {
        XCTAssertEqual(HistoryRules.quotaSeriesToken(index: 6), .tokenCacheRead)
        XCTAssertEqual(HistoryRules.quotaSeriesToken(index: 8), .seriesQuota)
    }

    func testTheAxisIsAFixedZeroToAHundredInQuarters() {
        XCTAssertEqual(HistoryRules.quotaAxisValues, [0, 25, 50, 75, 100])
    }

    func testTheTimeAxisMarksHoursDaysOrMonths() {
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .oneDay), HistoryAxisStride(component: .hour, count: 4))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .sevenDays), HistoryAxisStride(component: .day, count: 1))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .thirtyDays), HistoryAxisStride(component: .day, count: 4))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .ninetyDays), HistoryAxisStride(component: .day, count: 12))
        XCTAssertEqual(HistoryRules.quotaAxisStride(range: .oneYear), HistoryAxisStride(component: .month, count: 1))
    }

    // Review finding F1: the quota chart covers the cost chart's days (ruling S1).

    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    /// 2026-08-31 00:00 UTC, the first of the seven days ending 6 September.
    private let august31 = Date(timeIntervalSince1970: 1_788_134_400)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let buckets = [QuotaBucketInfo(id: "session", label: "Session", isCore: true, isLive: true)]

    func testSevenDaysOfQuotaAreTheCostChartsSevenCalendarDays() {
        let records = Fixture.quotaHistory(points: [
            (at: august31.addingTimeInterval(-4 * 3_600), percents: ["session": 70]),  // 30 Aug, 20:00
            (at: august31, percents: ["session": 20]),
        ])
        let series = HistoryRules.quotaSeries(records: records, buckets: buckets, range: .sevenDays, now: now, calendar: utc)
        XCTAssertEqual(series.first?.points.map(\.time), [august31], "30 August's evening is outside, 31 August's midnight inside")
        XCTAssertEqual(HistoryRules.quotaDomain(range: .sevenDays, now: now, calendar: utc), august31...now)
    }

    func testADayOfQuotaIsTheRolling24Hours() {
        XCTAssertEqual(
            HistoryRules.quotaDomain(range: .oneDay, now: now, calendar: utc),
            now.addingTimeInterval(-24 * 3_600)...now
        )
    }

    func testAWindowWithNoReadingInTheRangeDrawsNoLine() {
        let records = Fixture.quotaHistory(points: [(at: august31.addingTimeInterval(-3_600), percents: ["session": 70])])
        XCTAssertEqual(HistoryRules.quotaSeries(records: records, buckets: buckets, range: .sevenDays, now: now, calendar: utc), [])
    }

    /// The lines and the axis come from one `now`: the page caches this value and the
    /// card draws its domain, so the cutoff and the x extent cannot drift apart.
    func testTheLinesAndTheAxisShareOneDomain() {
        let records = Fixture.quotaHistory(points: [
            (at: august31, percents: ["session": 20]),
            (at: now.addingTimeInterval(-3_600), percents: ["session": 40]),
        ])
        for range in HistoryRules.ranges {
            let chart = HistoryRules.quotaChart(records: records, buckets: buckets, range: range, now: now, calendar: utc)
            XCTAssertEqual(chart.domain, HistoryRules.quotaDomain(range: range, now: now, calendar: utc), "\(range)")
            XCTAssertEqual(
                chart.series,
                HistoryRules.quotaSeries(records: records, buckets: buckets, range: range, now: now, calendar: utc),
                "\(range)"
            )
            XCTAssertTrue(chart.series.flatMap(\.points).allSatisfy { chart.domain.contains($0.time) }, "\(range)")
        }
    }
}

/// Liquid-glass spec § Screens, "History · Chart" and "History · Calendar"; § Decisions,
/// "Calendar in Tokens mode": two views, and the unit switch only over a cost chart.
final class HistoryRulesViewModeTests: XCTestCase {
    func testTheTwoViewsAreChartThenCalendar() {
        XCTAssertEqual(HistoryViewMode.allCases, [.chart, .calendar])
        XCTAssertEqual(HistoryViewMode.chart.displayName, "Chart")
        XCTAssertEqual(HistoryViewMode.calendar.displayName, "Calendar")
    }

    func testTheStoredValuesAreAContract() {
        XCTAssertEqual(HistoryRules.viewModeKey, "historyView")
        XCTAssertEqual(HistoryViewMode.chart.rawValue, "chart")
        XCTAssertEqual(HistoryViewMode.calendar.rawValue, "calendar")
        XCTAssertNil(HistoryViewMode(rawValue: "grid"), "an unknown stored value falls back to the default")
    }

    func testCostOrTokensIsOfferedOnlyOverACostChart() {
        XCTAssertTrue(HistoryRules.showsModePicker(view: .chart, showsQuota: false))
        XCTAssertFalse(HistoryRules.showsModePicker(view: .calendar, showsQuota: false), "the calendar is cost only")
        XCTAssertFalse(HistoryRules.showsModePicker(view: .chart, showsQuota: true), "a quota-only provider has one unit")
        XCTAssertFalse(HistoryRules.showsModePicker(view: .calendar, showsQuota: true))
    }
}
