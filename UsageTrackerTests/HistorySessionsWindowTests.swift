import XCTest
@testable import Omelette

/// Session ruling S4 (P5 plan): History's chat list covers the days its chart draws.
/// `DashboardState.refreshSessions` asks the aggregators for `sessionsWindow`, and they
/// return every chat with a turn inside it (`CostLogAggregating.sessions(from:to:)`).
final class HistorySessionsWindowTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    func testAtSevenDaysAChatFromTheEighthDayBackIsLeftOut() {
        let window = DashboardState.sessionsWindow(range: .sevenDays, now: now, calendar: calendar)
        // Its last turn at 23:59 on Sunday 30 August, the eighth day back.
        XCTAssertFalse(window.contains(day(-7).addingTimeInterval(23 * 3600 + 59 * 60)))
    }

    func testAtSevenDaysAChatFromTheSeventhDayBackIsListed() {
        let window = DashboardState.sessionsWindow(range: .sevenDays, now: now, calendar: calendar)
        XCTAssertTrue(window.contains(day(-6)), "a turn at midnight on Monday 31 August, the seventh day back")
        XCTAssertTrue(window.contains(now))
    }

    func testTheListCoversTheChartsDaysAtEveryRange() {
        for range in HistoryRules.ranges {
            XCTAssertEqual(
                DashboardState.sessionsWindow(range: range, now: now, calendar: calendar),
                HistoryRules.windowStart(range: range, now: now, calendar: calendar)...now,
                "\(range)"
            )
        }
    }

    func testTwentyFourHoursKeepsTheDayTheAggregatorsWidenedTo() {
        XCTAssertEqual(
            DashboardState.sessionsWindow(range: .oneDay, now: now, calendar: calendar).lowerBound,
            calendar.startOfDay(for: now.addingTimeInterval(-24 * 3600))
        )
    }
}
