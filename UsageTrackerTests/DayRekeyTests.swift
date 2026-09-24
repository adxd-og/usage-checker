import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design, "Shared
/// rule in Core": the midpoint rule both cost aggregators re-key a chat's folded days
/// with. Fixed epochs; every calendar carries its zone.
final class DayRekeyTests: XCTestCase {
    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-08-27 00:00 UTC.
    private let utcMidnight = Date(timeIntervalSince1970: 1_787_788_800)

    func testASavedMidnightKeepsItsDateInAHalfHourZone() {
        XCTAssertEqual(
            DayRekey.midpoint(utcMidnight, calendar: calendar(secondsFromGMT: 5 * 3600 + 1800)),
            Date(timeIntervalSince1970: 1_787_769_000),    // 2026-08-27 00:00 +05:30
            "the date the saved midnight named, not the 26th its instant falls on there"
        )
    }

    func testAMidnightSavedEastOfUTCKeepsItsDateWestOfIt() {
        let plus3Midnight = Date(timeIntervalSince1970: 1_787_778_000)    // 2026-08-27 00:00 +03:00
        XCTAssertEqual(
            DayRekey.midpoint(plus3Midnight, calendar: calendar(secondsFromGMT: -5 * 3600)),
            Date(timeIntervalSince1970: 1_787_806_800)                    // 2026-08-27 00:00 -05:00
        )
    }

    func testADaySavedInThisZoneMapsOntoItself() {
        XCTAssertEqual(DayRekey.midpoint(utcMidnight, calendar: calendar(secondsFromGMT: 0)), utcMidnight)
    }
}
