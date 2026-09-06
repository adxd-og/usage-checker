import XCTest
@testable import Omelette

final class ResetCopyTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC, built from components so the epoch cannot be off.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    func testRelativeCountsDownInTheAppsSpelling() {
        XCTAssertEqual(ResetCopy.relative(resetsAt: now.addingTimeInterval(70 * 60), now: now), "in 1h 10m")
        XCTAssertEqual(ResetCopy.relative(resetsAt: now.addingTimeInterval(45 * 60), now: now), "in 45m")
        XCTAssertEqual(ResetCopy.relative(resetsAt: now.addingTimeInterval(52 * 3600), now: now), "in 2d 4h")
        XCTAssertEqual(ResetCopy.relative(resetsAt: now.addingTimeInterval(-1), now: now), "now")
        XCTAssertNil(ResetCopy.relative(resetsAt: .distantFuture, now: now))
    }

    func testAbsoluteIsATimeTodayAWeekdayThisWeekAndADateBeyond() {
        XCTAssertEqual(ResetCopy.absolute(resetsAt: now.addingTimeInterval(100 * 60), now: now, calendar: calendar, locale: locale), "13:00")
        XCTAssertEqual(ResetCopy.absolute(resetsAt: now.addingTimeInterval(4 * 86_400 + 175 * 60), now: now, calendar: calendar, locale: locale), "Thu 14:15")
        XCTAssertEqual(ResetCopy.absolute(resetsAt: now.addingTimeInterval(8 * 86_400 + 175 * 60), now: now, calendar: calendar, locale: locale), "14 Sep, 14:15")
        XCTAssertNil(ResetCopy.absolute(resetsAt: .distantFuture, now: now, calendar: calendar, locale: locale))
    }

    func testBothKeepsTheCountdownAloneWithinTheHour() {
        XCTAssertEqual(ResetCopy.both(resetsAt: now.addingTimeInterval(45 * 60), now: now, calendar: calendar, locale: locale), "resets in 45m")
        XCTAssertEqual(ResetCopy.both(resetsAt: now.addingTimeInterval(100 * 60), now: now, calendar: calendar, locale: locale), "resets in 1h 40m (13:00)")
        XCTAssertEqual(ResetCopy.both(resetsAt: now.addingTimeInterval(-5), now: now, calendar: calendar, locale: locale), "resets now")
        XCTAssertNil(ResetCopy.both(resetsAt: .distantFuture, now: now, calendar: calendar, locale: locale))
    }
}
