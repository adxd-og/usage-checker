import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Time zone: "the Activity grid matches by `isDate(_:inSameDayAs:)`, not `Date`
/// equality." A daily row is keyed by the midnight of the zone it was binned in, the
/// grid walks its own calendar's midnights, and equality between the two left a square
/// blank while the cards above still counted its dollars (report B #3).
final class ActivityGridDayMatchTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    /// 2026-08-27 00:00 UTC.
    private let utcMidnight = Date(timeIntervalSince1970: 1_787_788_800)
    /// 2026-08-27 00:00 at UTC+3.
    private let plus3Midnight = Date(timeIntervalSince1970: 1_787_778_000)

    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func row(_ day: Date, cost: Double, turns: Int = 1) -> CLIDailySummary {
        CLIDailySummary(
            day: day, totalCost: cost, totalTokens: 1_000, tokens: TokenBreakdown(input: 1_000),
            turns: turns, byFamily: ["sonnet": cost]
        )
    }

    func testARowBinnedInAnotherZoneFillsTheSquareOfItsDate() {
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let cache = GridCache.build(from: [row(utcMidnight, cost: 5)], weeks: 52, now: now, calendar: plus3)
        XCTAssertEqual(cache.value(on: plus3Midnight), 5)
    }

    func testTheCardsAndTheSquareCountTheSameRow() {
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let cache = GridCache.build(from: [row(utcMidnight, cost: 5)], weeks: 52, now: now, calendar: plus3)
        XCTAssertEqual(cache.stats[0].value, "$5.00", "ten days back is inside the 30-day card")
        XCTAssertEqual(cache.value(on: plus3Midnight), 5)
    }

    func testTwoRowsOnOneDateAddUp() {
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let merged = GridCache.dailiesByDay(
            [row(utcMidnight, cost: 2, turns: 1), row(plus3Midnight, cost: 3, turns: 2)],
            calendar: plus3
        )
        XCTAssertEqual(merged.map(\.day), [plus3Midnight])
        XCTAssertEqual(merged.first?.totalCost ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(merged.first?.turns, 3)
        XCTAssertEqual(merged.first?.totalTokens, 2_000)
        XCTAssertEqual(merged.first?.tokens.input, 2_000)
        XCTAssertEqual(merged.first?.byFamily["sonnet"] ?? 0, 5, accuracy: 1e-9)
    }

    func testARowOnThisCalendarsMidnightStaysWhereItIs() {
        let merged = GridCache.dailiesByDay([row(utcMidnight, cost: 2)], calendar: calendar(secondsFromGMT: 0))
        XCTAssertEqual(merged.map(\.day), [utcMidnight])
    }
}
