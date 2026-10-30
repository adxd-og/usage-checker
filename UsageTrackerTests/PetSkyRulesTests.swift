import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 ("a sky following the local clock"), the habitat advisory
/// § 4 (day, dusk, night; the moon from 22:00 to 06:00, keep awake's night) and the owner's notes
/// of 2026-10-30 (no fill, no edge; the sky stays): one mark, read on the clock of the calendar's
/// time zone.
final class PetSkyRulesTests: XCTestCase {
    /// Monday 2026-10-26 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_792_972_800)

    private func sky(_ hour: Int, _ minute: Int, in zone: String = "UTC") -> PetSky {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return PetSkyRules.sky(
            at: midnight.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60)), calendar: calendar
        )
    }

    func testTheSkyFollowsTheLocalClock() {
        XCTAssertEqual(sky(5, 59), .night, "05:59")
        XCTAssertEqual(sky(6, 0), .day, "06:00")
        XCTAssertEqual(sky(17, 59), .day, "17:59")
        XCTAssertEqual(sky(18, 0), .dusk, "18:00")
        XCTAssertEqual(sky(21, 59), .dusk, "21:59")
        XCTAssertEqual(sky(22, 0), .night, "22:00")
    }

    func testTheSkyIsReadOnTheCalendarsClock() {
        XCTAssertEqual(sky(13, 48), .day, "13:48 in UTC")
        XCTAssertEqual(sky(13, 48, in: "Asia/Tokyo"), .night, "the same moment is 22:48 in Tokyo")
    }

    func testEachSkyHasItsMark() {
        XCTAssertEqual(PetSkyRules.symbol(.day), "sun.max")
        XCTAssertEqual(PetSkyRules.symbol(.dusk), "sunset")
        XCTAssertEqual(PetSkyRules.symbol(.night), "moon.stars")
    }
}
