import XCTest
@testable import Omelette

/// Every string on the Insights tab (liquid-glass spec § Screens, "Insights";
/// `Dashboard-Insights(-Light).dc.html`). Locales and calendars are pinned.
final class InsightsCopyTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    // MARK: - Days at limit

    /// The mockup's card: title, `[n] of 7`, and the caption naming the threshold.
    func testDaysAtLimitReadsAsTheMockupsNOfSeven() {
        XCTAssertEqual(InsightsCopy.daysAtLimitTitle, "Days at limit, 7 days")
        XCTAssertEqual(InsightsCopy.daysAtLimit(0), "0 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimit(1), "1 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimit(3), "3 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimitCaption, "days the peak reached 95%")
    }

    func testAWeekWithoutAReadingHasNoDaysAtLimitToShow() {
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)), "—"
        )
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 0, observed: 4, span: 7)), "0 of 7"
        )
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 2, observed: 5, span: 7)), "2 of 7"
        )
    }

    // MARK: - Dollars

    /// The mockup's "$2,727.56": grouped, as the popover's cost tile prints dollars.
    func testDollarsAreThePopoversFormat() {
        XCTAssertEqual(InsightsCopy.money(2_727.56, locale: us), "$2,727.56")
        XCTAssertEqual(InsightsCopy.money(0.98, locale: us), "$0.98")
        XCTAssertEqual(InsightsCopy.money(1_352.28, locale: us), OMCostTile.money(1_352.28, locale: us))
    }
}
