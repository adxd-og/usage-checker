import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Time
/// zone (report B #3): "the Activity grid matches by `isDate(_:inSameDayAs:)`, not
/// `Date` equality." `GridCache.dailiesByDay` re-keys every row to the calendar's own
/// midnight before the grid ever looks a date up, and two rows that land on the same
/// calendar date after re-keying must add rather than overwrite one another (the
/// v6→v7 double-count risk the report calls out as a second effect of the same bug).
///
/// Written independently of `ActivityGridDayMatchTests.swift`: its own zone pair
/// (UTC / UTC-5, not UTC / UTC+3) and its own merge scenario (three rows, one already
/// on the target zone's midnight).
final class ActivityGridViewVerificationTests: XCTestCase {
    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func row(_ day: Date, cost: Double, tokens: Int = 100, turns: Int = 1) -> CLIDailySummary {
        CLIDailySummary(
            day: day, totalCost: cost, totalTokens: tokens, tokens: TokenBreakdown(input: tokens),
            turns: turns, byFamily: ["opus": cost]
        )
    }

    func testARowFoldedInUTCFillsItsSquareUnderUTCMinusFive() {
        let minus5 = calendar(secondsFromGMT: -5 * 3600)
        // 2026-08-27 00:00 UTC.
        let utcMidnight = Date(timeIntervalSince1970: 1_787_788_800)
        // The same calendar date's midnight at UTC-5.
        let minus5Midnight = minus5.startOfDay(for: utcMidnight)

        let cache = GridCache.build(from: [row(utcMidnight, cost: 12)], weeks: 12, calendar: minus5)

        XCTAssertEqual(cache.value(on: minus5Midnight), 12)
        XCTAssertNil(cache.value(on: utcMidnight), "the raw UTC midnight is not a date this calendar draws a square for")
    }

    /// Three separately-folded rows — two of them at different raw `Date`s that both
    /// name the same UTC-5 calendar date, one already sitting exactly on that date's
    /// midnight — must be summed into one square, not have the last one silently win.
    func testThreeRowsThatNameOneCalendarDateAllAddIntoOneSquare() throws {
        let minus5 = calendar(secondsFromGMT: -5 * 3600)
        let targetDay = minus5.date(from: DateComponents(year: 2026, month: 8, day: 27))!

        // Row A: exactly UTC-5's midnight for 2026-08-27 already.
        let rowA = row(targetDay, cost: 4, tokens: 40, turns: 1)
        // Row B: 2026-08-27 20:00 UTC — 15:00 local at UTC-5, still the 27th there
        // (UTC-5's 27th spans UTC 05:00 that day through UTC 05:00 the next).
        let utcEvening = calendar(secondsFromGMT: 0)
            .date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 20))!
        let rowB = row(utcEvening, cost: 7, tokens: 70, turns: 2)
        // Row C: a folded UTC+3 midnight for the 27th — 21:00 UTC-5 the PREVIOUS day
        // (2026-08-26), so it must NOT merge with A/B.
        let plus3Midnight = calendar(secondsFromGMT: 3 * 3600)
            .date(from: DateComponents(year: 2026, month: 8, day: 27))!
        let rowC = row(plus3Midnight, cost: 100, tokens: 1, turns: 1)

        let merged = GridCache.dailiesByDay([rowA, rowB, rowC], calendar: minus5)

        let target = try XCTUnwrap(merged.first { $0.day == targetDay })
        XCTAssertEqual(target.totalCost, 11, "rows A and B both name 2026-08-27 at UTC-5 and must sum")
        XCTAssertEqual(target.totalTokens, 110)
        XCTAssertEqual(target.turns, 3)
        XCTAssertEqual(target.byFamily["opus"], 11)

        XCTAssertFalse(
            merged.contains { $0.day == targetDay && $0.totalCost == 111 },
            "row C (a different UTC-5 date) must not be folded into the 27th's square"
        )
        XCTAssertEqual(merged.count, 2, "two distinct UTC-5 dates in, two rows out")
    }

    func testAnEmptyInputProducesAnEmptyMergeWithNoCrash() {
        let utc = calendar(secondsFromGMT: 0)
        XCTAssertTrue(GridCache.dailiesByDay([], calendar: utc).isEmpty, "vacuous but must not trap")
    }
}
