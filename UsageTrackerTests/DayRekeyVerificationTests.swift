import XCTest
@testable import Omelette

/// Verification of `DayRekey.midpoint` against
/// docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design, "Shared rule
/// in Core": "the start, in `calendar`, of the date the saved midnight named. The
/// midday after a saved midnight is still that date in any zone less than twelve hours
/// away". Cases the executor's own `DayRekeyTests` did not reach: the documented
/// boundary at exactly twelve hours, a negative half-hour zone, a quarter-hour zone,
/// and reflexivity in a non-UTC zone. Fixed epochs, every calendar carries its own zone.
final class DayRekeyVerificationTests: XCTestCase {
    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-08-27 00:00 UTC.
    private let utcMidnight = Date(timeIntervalSince1970: 1_787_788_800)

    /// § Design: "less than twelve hours away". At exactly +12h the saved midnight's
    /// midpoint (`saved + 12h`) is itself the new zone's next midnight, so the rule
    /// tips the day forward instead of keeping it — the "documented inaccuracy" the
    /// spec's "Not doing" section names, pinned at its exact edge rather than asserted
    /// away.
    func testASavedMidnightIsPushedToTheNextDayAtExactlyTwelveHoursEast() {
        let plus12 = calendar(secondsFromGMT: 12 * 3600)
        let rekeyed = DayRekey.midpoint(utcMidnight, calendar: plus12)
        XCTAssertEqual(
            rekeyed, utcMidnight.addingTimeInterval(12 * 3600),
            "the +12 midnight that follows the saved one, not the date it named"
        )
        XCTAssertNotEqual(
            plus12.startOfDay(for: utcMidnight), rekeyed,
            "so this is really the day after the one +12 would bin the original instant into"
        )
    }

    /// The mirror case: at exactly −12h the rule still lands on the date the saved
    /// midnight named — `saved + 12h` reads as that zone's midnight of the same civil
    /// date — where binning the saved instant directly, with no midpoint, would read
    /// one day earlier. The two edges are not symmetric.
    func testASavedMidnightKeepsItsDateAtExactlyTwelveHoursWest() {
        let minus12 = calendar(secondsFromGMT: -12 * 3600)
        let rekeyed = DayRekey.midpoint(utcMidnight, calendar: minus12)
        XCTAssertEqual(
            rekeyed, utcMidnight.addingTimeInterval(12 * 3600),
            "the −12 midnight that still reads as the date the saved midnight named"
        )
        XCTAssertNotEqual(
            minus12.startOfDay(for: utcMidnight), rekeyed,
            "unlike binning the saved instant directly, which loses a day here"
        )
    }

    /// A negative half-hour zone (Newfoundland-shaped, UTC−3:30): the saved midnight's
    /// date survives the same way a positive half-hour zone's does.
    func testASavedMidnightKeepsItsDateInANegativeHalfHourZone() {
        let minus3h30 = calendar(secondsFromGMT: -3 * 3600 - 1800)
        XCTAssertEqual(
            DayRekey.midpoint(utcMidnight, calendar: minus3h30),
            Date(timeIntervalSince1970: 1_787_801_400)    // 2026-08-27 00:00 −03:30
        )
    }

    /// A quarter-hour zone (Nepal-shaped, UTC+5:45): the rule is exact arithmetic, not
    /// a table of known offsets, so an offset nobody hardcoded still keeps the date.
    func testASavedMidnightKeepsItsDateInAQuarterHourZone() {
        let plus5h45 = calendar(secondsFromGMT: 5 * 3600 + 2700)
        XCTAssertEqual(
            DayRekey.midpoint(utcMidnight, calendar: plus5h45),
            Date(timeIntervalSince1970: 1_787_768_100)    // 2026-08-27 00:00 +05:45
        )
    }

    /// A day already re-keyed into a zone stays there on a second pass with the same
    /// calendar — the property `rebinChats()` relies on to leave an unmoved cache
    /// exactly as it was on every relaunch in the same zone.
    func testMidpointIsIdempotentOnASecondPassInTheSameNonUTCZone() {
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let once = DayRekey.midpoint(utcMidnight, calendar: plus3)
        let twice = DayRekey.midpoint(once, calendar: plus3)
        XCTAssertEqual(once, twice)
    }

    /// A day saved in a non-UTC zone maps onto itself in that same zone — reflexivity
    /// is not a UTC-only property.
    func testADaySavedInANonUTCZoneMapsOntoItselfInThatZone() {
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        let plus3Midnight = Date(timeIntervalSince1970: 1_787_778_000)    // 2026-08-27 00:00 +03:00
        XCTAssertEqual(DayRekey.midpoint(plus3Midnight, calendar: plus3), plus3Midnight)
    }
}
