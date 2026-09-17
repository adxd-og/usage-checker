import XCTest
@testable import Omelette

/// Dashboard → Activity's three cost cards, built from the daily rows an aggregator
/// hands the dashboard.
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md § Cards.
final class ActivityGridCacheTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func daily(_ dayOffset: Int, cost: Double) -> CLIDailySummary {
        let cal = utc
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
        return CLIDailySummary(
            day: day,
            totalCost: cost,
            totalTokens: 0,
            tokens: .zero,
            turns: cost > 0 ? 1 : 0,
            byFamily: [:]
        )
    }

    /// One power of two per boundary, so a card that counts the wrong day says so in
    /// its total instead of hiding inside a rounding difference.
    private var dailies: [CLIDailySummary] {
        [
            daily(0, cost: 1),       // today
            daily(-10, cost: 0),     // a day the CLI ran and spent nothing
            daily(-29, cost: 2),     // the 30-day card's boundary day
            daily(-30, cost: 4),     // one day past it
            daily(-89, cost: 8),     // the 90-day card's boundary day
            daily(-200, cost: 16),   // only the year can see this
            daily(-364, cost: 32),   // the year card's boundary day
            daily(-365, cost: 64),   // one day past it
        ]
    }

    private func stats() -> [GridStat] {
        GridCache.build(from: dailies, weeks: 52, now: now, calendar: utc).stats
    }

    func testTheThirtyDayCardCountsItsBoundaryDayAndStopsThere() {
        XCTAssertEqual(stats()[0].label, "Last 30 days")
        XCTAssertEqual(stats()[0].value, "$3.00", "today + the 29-days-back boundary")
    }

    func testTheNinetyDayCardReachesItsBoundaryDay() {
        XCTAssertEqual(stats()[1].label, "Last 90 days")
        XCTAssertEqual(stats()[1].value, "$15.00", "plus the days 30 and 89 back")
    }

    /// The whole point of the package: a day two hundred days old carries cost, and
    /// the year card is the only one that can count it.
    func testTheYearCardCountsDaysTheNinetyDayCardCannot() {
        let s = stats()
        XCTAssertEqual(s[2].label, "Last year")
        XCTAssertEqual(s[2].value, "$63.00", "plus the days 200 and 364 back; 365 is out")
        XCTAssertNotEqual(s[2].value, s[1].value)
    }

    func testActiveDaysCountsOnlyDaysWithCost() {
        XCTAssertEqual(stats()[2].sub, "6 active days", "the zero-cost day is not an active day")
    }
}
