import XCTest
@testable import Omelette

/// Whole-branch review of 2.7.0 (Codex, 2026-09-24): two saved midnights of one date.
final class JSONLDayTotalsCollisionTests: XCTestCase {
    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// A day folded before and after a time-zone change in one run is saved under two
    /// midnights. Loading it under either zone adds the two, never keeps only one.
    func testTwoSavedMidnightsOfOneDateAddUpOnLoad() {
        let utc = calendar(secondsFromGMT: 0)
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let date = DateComponents(year: 2026, month: 8, day: 10)
        let entries = [
            JSONLAggregator.DayEntry(day: utc.date(from: date)!, cost: 2, tokens: 20, breakdown: TokenBreakdown(input: 20), turns: 1, byFamily: ["opus": 2]),
            JSONLAggregator.DayEntry(day: plus3.date(from: date)!, cost: 3, tokens: 30, breakdown: TokenBreakdown(input: 30), turns: 2, byFamily: ["opus": 1, "sonnet": 2]),
        ]
        let days = JSONLAggregator.dayTotals(from: entries, calendar: plus3)
        XCTAssertEqual(days.count, 1)
        let day = try! XCTUnwrap(days[plus3.date(from: date)!])
        XCTAssertEqual(day.cost, 5, accuracy: 1e-12)
        XCTAssertEqual(day.tokens, 50)
        XCTAssertEqual(day.turns, 3)
        XCTAssertEqual(day.byFamily["opus"] ?? 0, 3, accuracy: 1e-12)
        XCTAssertEqual(day.byFamily["sonnet"] ?? 0, 2, accuracy: 1e-12)
    }
}
