import XCTest
@testable import Omelette

/// Independent verification of `DashboardState.sessionsWindow` against session ruling
/// S4 (docs/superpowers/plans/2026-09-25-3.0-P5-history.md): the chat list's aggregator
/// query covers exactly the days `HistoryRules.windowStart` gives the chart, so a chat
/// from a day the chart drops is never listed.
final class DashboardStateSessionsWindowVerificationTests: XCTestCase {
    /// 2026-09-06 15:20 UTC — a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_708_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func testSevenDayWindowExcludesTheEighthDayBackAndIncludesTheSeventh() {
        let window = DashboardState.sessionsWindow(range: .sevenDays, now: now, calendar: calendar)
        // The eighth day back: its whole day, up to 23:59:59, must sit before the window.
        let eighthDayBack = day(-7).addingTimeInterval(86_399)
        XCTAssertLessThan(eighthDayBack, window.lowerBound, "a chat on the eighth day back must be excluded")
        // The seventh day back (day(-6)) is the window's first day, start included.
        XCTAssertEqual(window.lowerBound, day(-6))
        XCTAssertTrue(day(-6) >= window.lowerBound && day(-6) <= window.upperBound)
    }

    func testSevenDayWindowMatchesHistoryRulesWindowStartExactly() {
        let window = DashboardState.sessionsWindow(range: .sevenDays, now: now, calendar: calendar)
        let ruleStart = HistoryRules.windowStart(range: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(window.lowerBound, ruleStart)
        XCTAssertEqual(window.upperBound, now)
    }

    func testThirtyNinetyAndOneYearWindowsMatchHistoryRulesWindowStart() {
        for range: TimeRange in [.thirtyDays, .ninetyDays, .oneYear] {
            let window = DashboardState.sessionsWindow(range: range, now: now, calendar: calendar)
            XCTAssertEqual(window.lowerBound, HistoryRules.windowStart(range: range, now: now, calendar: calendar), "\(range)")
        }
    }

    func test24hStaysTheRollingLocalDayTheAggregatorsAlreadyWidenedTo() {
        let window = DashboardState.sessionsWindow(range: .oneDay, now: now, calendar: calendar)
        // now - 24h = Sept 5 15:20; the local day that falls in starts Sept 5 00:00.
        XCTAssertEqual(window.lowerBound, day(-1))
        XCTAssertEqual(window.upperBound, now)
    }

    func testFiveHoursAlsoUsesTheRollingFormulaAgentsWidenedTo() {
        // 5h is not one of History's own ranges, but Agents can still set it, and the
        // aggregators already widen "5h" queries to the whole local day.
        let window = DashboardState.sessionsWindow(range: .fiveHours, now: now, calendar: calendar)
        XCTAssertEqual(window.lowerBound, calendar.startOfDay(for: now.addingTimeInterval(-TimeRange.fiveHours.seconds)))
    }
}
