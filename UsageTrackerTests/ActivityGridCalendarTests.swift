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
