import XCTest
@testable import Omelette

/// Verification of plan ruling R15 (the island's words through `PopoverCopy`) and
/// `KeepAwakeCopy.fieldPlaceholder`: the cannot-refresh notice names the time in the
/// calendar's own time zone and the locale's clock, not the machine's.
final class PopoverCopyVerificationTests: XCTestCase {
    /// 2026-10-04 12:05 UTC, a Sunday.
    private let noonUTC = Date(timeIntervalSince1970: 1_791_115_500)

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testTheNoticeNamesTheTimeInTheCalendarsZoneWhateverTheMachinesIs() {
        let british = Locale(identifier: "en_GB")
        XCTAssertEqual(PopoverCopy.staleNotice(fetchedAt: noonUTC, calendar: calendar("Asia/Tokyo"), locale: british),
                       "Can't refresh — showing data from 21:05")
        // The hour's padding is the locale's business; the zone's 05:05 is not.
        let pacific = PopoverCopy.staleNotice(fetchedAt: noonUTC, calendar: calendar("America/Los_Angeles"), locale: british)
        XCTAssertTrue(pacific.hasPrefix("Can't refresh — showing data from ") && pacific.hasSuffix("5:05"), pacific)
        XCTAssertFalse(pacific.hasSuffix("12:05"), pacific)
        XCTAssertEqual(PopoverCopy.staleNotice(fetchedAt: noonUTC, calendar: calendar("UTC"), locale: british),
                       "Can't refresh — showing data from 12:05")
    }

    func testTheNoticeUsesTheLocalesClockStyle() {
        let utc = calendar("UTC")
        let twelveHour = PopoverCopy.staleNotice(fetchedAt: noonUTC, calendar: utc, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(twelveHour.hasPrefix("Can't refresh — showing data from 12:05"), twelveHour)
        XCTAssertTrue(twelveHour.hasSuffix("PM"), twelveHour)
        let midnight = Date(timeIntervalSince1970: 1_791_072_300) // 00:05 UTC the same day
        let night = PopoverCopy.staleNotice(fetchedAt: midnight, calendar: utc, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(night.hasSuffix("0:05"), night)
        XCTAssertFalse(night.contains("AM") || night.contains("12:05"), "a 24-hour locale says 0:05, not 12:05 AM: \(night)")
    }

    func testTheKeepAwakeFieldPlaceholderIsTheNumberAnEmptyFieldMeans() {
        XCTAssertEqual(Int(KeepAwakeCopy.fieldPlaceholder), KeepAwakeCopy.fieldNumber(""), "an empty field reads as the placeholder says")
    }
}
