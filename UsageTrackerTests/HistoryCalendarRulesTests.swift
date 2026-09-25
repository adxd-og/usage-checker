import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "History · Calendar": the heatmap covers the page's
/// range in whole weeks of the Mac's calendar, and cost squares climb the mockup's
/// five-step yolk ramp.
final class HistoryCalendarRulesTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = firstWeekday
        return c
    }

    private func weeks(_ range: TimeRange, firstWeekday: Int) -> Int {
        let cal = calendar(firstWeekday: firstWeekday)
        return HistoryCalendarRules.weeks(
            from: HistoryRules.windowStart(range: range, now: now, calendar: cal), now: now, calendar: cal
        )
    }

    func testAMondayFirstCalendarDrawsTheRangesWeeks() {
        // 24h, 7d, 30d, 90d, 1y: Sunday 6 Sep closes the week of Monday 31 Aug.
        XCTAssertEqual(HistoryRules.ranges.map { weeks($0, firstWeekday: 2) }, [1, 1, 5, 13, 53])
    }

    func testASundayFirstCalendarCountsItsOwnWeeks() {
        XCTAssertEqual(HistoryRules.ranges.map { weeks($0, firstWeekday: 1) }, [2, 2, 6, 14, 53])
    }

    func testCostSquaresClimbFourSteps() {
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0), 0)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: -1), 0)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.01), 1)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.25), 1)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.26), 2)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.5), 2)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.75), 3)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 0.76), 4)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 1), 4)
        XCTAssertEqual(HistoryCalendarRules.costLevel(intensity: 1.5), 4)
    }

    func testTheStepsAreTheMockupsMixes() {
        XCTAssertEqual(HistoryCalendarRules.legendLevels.map(HistoryCalendarRules.levelOpacity), [0, 0.28, 0.5, 0.75, 1])
    }

    func testTheLegendShowsEveryStep() {
        XCTAssertEqual(HistoryCalendarRules.legendLevels, [0, 1, 2, 3, 4])
    }
}

/// Review finding F2: the calendar counts the range's days through today and nothing
/// after, so a reading or a row stamped tomorrow (a clock set back) changes nothing.
final class HistoryCalendarBoundsTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func testTheRangeEndsAtTheStartOfTomorrow() {
        XCTAssertEqual(HistoryCalendarRules.windowEnd(now: now, calendar: calendar), day(1))
    }

    func testATomorrowReadingNeitherCountsNorFillsADay() {
        let records = Fixture.quotaHistory(points: [
            (at: day(0).addingTimeInterval(3_600), percents: ["session": 50]),
            (at: day(1).addingTimeInterval(3_600), percents: ["session": 100]),
        ])
        let buckets = [QuotaBucketInfo(id: "session", label: "Session", isCore: true, isLive: true)]
        XCTAssertEqual(
            HistoryCalendarRules.quotaRecords(records, range: .sevenDays, now: now, calendar: calendar).count, 1
        )
        let summary = HistoryCalendarRules.quotaSummary(
            records: records, buckets: buckets, range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(summary, HistoryCalendarQuotaSummary(daysAtLimit: 0, daysObserved: 1))
        XCTAssertEqual(HistoryCopy.daysAtLimit(summary.daysAtLimit, of: summary.daysObserved), "0 of 1 day at limit")
    }

    func testATomorrowRowDoesNotRaiseTheRangesTopStep() {
        func row(_ offset: Int, cost: Double) -> CLIDailySummary {
            CLIDailySummary(day: day(offset), totalCost: cost, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:])
        }
        let kept = HistoryCalendarRules.costRows(
            [row(0, cost: 10), row(1, cost: 1_000)], range: .sevenDays, now: now, calendar: calendar
        )
        XCTAssertEqual(kept.map(\.totalCost), [10])
        let grid = GridCache.build(
            from: kept, weeks: 1, now: now, calendar: calendar,
            notBefore: HistoryRules.windowStart(range: .sevenDays, now: now, calendar: calendar)
        )
        XCTAssertEqual(grid.scaleMax, 10, "today's $10 square is the range's busiest")
        XCTAssertEqual(grid.value(on: day(0)), 10)
    }
}
