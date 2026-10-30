import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 and plan ruling R15: the words the island's content
/// moved out of the 3.x popover keep their text and go through `PopoverCopy` — the strip's
/// title, the loading row, the cannot-refresh notice and its tooltip, the first segment.
final class PopoverCopyIslandTests: XCTestCase {
    /// Sunday 2026-10-04 12:00 UTC.
    private let october4 = Date(timeIntervalSince1970: 1_791_115_200)

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testTheStripSaysOmeletteAndTheLoadingRowSaysLoading() {
        XCTAssertEqual(PopoverCopy.appName, "Omelette")
        XCTAssertEqual(PopoverCopy.loading, "Loading…")
    }

    func testTheCannotRefreshNoticeSaysWhenTheDataIsFrom() {
        XCTAssertEqual(
            PopoverCopy.staleNotice(fetchedAt: october4, calendar: utc, locale: Locale(identifier: "en_GB")),
            "Can't refresh — showing data from 12:00"
        )
    }

    func testTheNoticesTooltipIsTheLastErrorOrAPlainFallback() {
        XCTAssertEqual(PopoverCopy.staleNoticeHelp(lastError: "HTTP 503"), "HTTP 503")
        XCTAssertEqual(PopoverCopy.staleNoticeHelp(lastError: nil), "The last refresh attempt failed.")
    }

    func testTheFirstSegmentIsAll() {
        XCTAssertEqual(PopoverCopy.allSegment, "All")
    }
}
