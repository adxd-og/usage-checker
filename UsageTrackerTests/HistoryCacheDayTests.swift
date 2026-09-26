import XCTest
@testable import Omelette

/// Spec § Screens, History: the chart's domain and the calendar's "today" follow the
/// clock. A cache keyed on the records alone stands still across midnight for a
/// provider that has stopped reporting, so the key carries the day it was built for.
final class HistoryCacheDayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    func testTwoInstantsOnOneDayShareAKey() {
        // 2026-09-06 (Sunday) 08:00 and 22:30 Berlin.
        let morning = Date(timeIntervalSince1970: 1_788_674_400)
        let evening = Date(timeIntervalSince1970: 1_788_726_600)
        XCTAssertEqual(
            HistoryRules.cacheDay(now: morning, calendar: calendar),
            HistoryRules.cacheDay(now: evening, calendar: calendar)
        )
    }

    func testMidnightChangesTheKeyWithoutAnyNewRecord() {
        // 2026-09-06 23:59:30 and 2026-09-07 00:00:30 Berlin.
        let before = Date(timeIntervalSince1970: 1_788_731_970)
        let after = Date(timeIntervalSince1970: 1_788_732_030)
        XCTAssertNotEqual(
            HistoryRules.cacheDay(now: before, calendar: calendar),
            HistoryRules.cacheDay(now: after, calendar: calendar)
        )
        XCTAssertEqual(
            HistoryRules.cacheDay(now: after, calendar: calendar),
            Date(timeIntervalSince1970: 1_788_732_000)
        )
    }
}
