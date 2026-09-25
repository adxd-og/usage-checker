import XCTest
@testable import Omelette

/// History → Calendar (liquid-glass spec § Screens, "History · Calendar"; D9 of the P5
/// plan): the grid's weeks start on the calendar's first weekday, and its rows are named
/// in the week's own order.
final class ActivityGridWeekTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = firstWeekday
        return c
    }

    private func day(_ offset: Int, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    private func row(_ day: Date, cost: Double) -> CLIDailySummary {
        CLIDailySummary(day: day, totalCost: cost, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:])
    }

    func testAMondayFirstCalendarPutsSundayAtTheEndOfItsWeek() {
        let cal = calendar(firstWeekday: 2)
        XCTAssertEqual(GridCache.weekStart(of: now, calendar: cal), day(-6, cal), "Sunday 6 Sep closes the week of Monday 31 Aug")
    }

    func testASundayFirstCalendarStartsTheWeekThatSunday() {
        let cal = calendar(firstWeekday: 1)
        XCTAssertEqual(GridCache.weekStart(of: now, calendar: cal), day(0, cal))
    }

    func testOneMondayFirstWeekHoldsMondayThroughToday() {
        let cal = calendar(firstWeekday: 2)
        let cache = GridCache.build(
            from: [row(day(-7, cal), cost: 1), row(day(-6, cal), cost: 2), row(day(0, cal), cost: 3)],
            weeks: 1, now: now, calendar: cal
        )
        XCTAssertNil(cache.value(on: day(-7, cal)), "Sunday 30 Aug is last week's column")
        XCTAssertEqual(cache.value(on: day(-6, cal)), 2)
        XCTAssertEqual(cache.value(on: day(0, cal)), 3)
    }

    func testOneSundayFirstWeekHoldsOnlyToday() {
        let cal = calendar(firstWeekday: 1)
        let cache = GridCache.build(
            from: [row(day(-1, cal), cost: 1), row(day(0, cal), cost: 3)],
            weeks: 1, now: now, calendar: cal
        )
        XCTAssertNil(cache.value(on: day(-1, cal)))
        XCTAssertEqual(cache.value(on: day(0, cal)), 3)
    }

    func testTheRowsAreNamedMonWedFriInTheWeeksOwnOrder() {
        XCTAssertEqual(GridCache.weekdayLabels(calendar: calendar(firstWeekday: 2)), ["Mon", "", "Wed", "", "Fri", "", ""])
        XCTAssertEqual(GridCache.weekdayLabels(calendar: calendar(firstWeekday: 1)), ["", "Mon", "", "Wed", "", "Fri", ""])
    }
}

/// The calendar over a range (P5 plan, D4): squares before the range's first day are
/// blank even when a row exists for them, and the cache knows which square is today.
final class ActivityGridRangeTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        c.firstWeekday = 2
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func row(_ offset: Int, cost: Double) -> CLIDailySummary {
        CLIDailySummary(day: day(offset), totalCost: cost, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:])
    }

    func testADayBeforeTheRangeIsBlankEvenWithARow() {
        let cache = GridCache.build(
            from: [row(-6, cost: 1), row(-2, cost: 2)],
            weeks: 1, now: now, calendar: calendar, notBefore: day(-4)
        )
        XCTAssertNil(cache.value(on: day(-6)), "Monday is in the grid's week but before the range")
        XCTAssertEqual(cache.value(on: day(-2)), 2)
    }

    func testWithoutARangeEveryPastDayOfTheWeeksIsDrawn() {
        let cache = GridCache.build(from: [row(-6, cost: 1)], weeks: 1, now: now, calendar: calendar)
        XCTAssertEqual(cache.value(on: day(-6)), 1)
    }

    func testTheCacheKnowsWhichSquareIsToday() {
        XCTAssertEqual(GridCache.build(from: [], weeks: 1, now: now, calendar: calendar).today, day(0))
    }

    func testTheQuotaGridTakesTheSameClockCalendarAndRange() {
        let records = Fixture.quotaHistory(points: [
            (at: day(-6).addingTimeInterval(3_600), percents: ["session": 40]),
            (at: day(-2).addingTimeInterval(3_600), percents: ["session": 80]),
        ])
        let buckets = [QuotaBucketInfo(id: "session", label: "Session", isCore: true, isLive: true)]
        let cache = GridCache.build(
            records: records, buckets: buckets, weeks: 1,
            now: now, calendar: calendar, notBefore: day(-4)
        )
        XCTAssertNil(cache.value(on: day(-6)))
        XCTAssertEqual(cache.value(on: day(-2)), 80)
        XCTAssertEqual(cache.today, day(0))
    }
}
