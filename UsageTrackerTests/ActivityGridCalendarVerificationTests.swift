import XCTest
@testable import Omelette

/// Independent verification of `GridCache`'s calendar-week arithmetic and
/// `ActivityGridView`'s pure square rules, against liquid-glass spec § Decisions "D9.
/// Weeks start on the calendar's first weekday" and § Screens "History · Calendar".
final class ActivityGridCalendarVerificationTests: XCTestCase {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.firstWeekday = firstWeekday
        return c
    }

    /// 2026-09-09, a Wednesday (Sept 6 is a Sunday).
    private let wednesday = Date(timeIntervalSince1970: 1_788_955_200)
    /// 2026-09-06, a Sunday.
    private let sunday = Date(timeIntervalSince1970: 1_788_696_000)

    // MARK: - weekStart follows the calendar's own first weekday, not a hardcoded Sunday

    func testWeekStartOnAMondayFirstCalendarIsThatWeeksMonday() {
        let mondayFirst = calendar(firstWeekday: 2)
        let start = GridCache.weekStart(of: wednesday, calendar: mondayFirst)
        XCTAssertEqual(mondayFirst.component(.weekday, from: start), 2, "must land on a Monday")
        XCTAssertLessThanOrEqual(start, wednesday)
        XCTAssertGreaterThan(mondayFirst.date(byAdding: .day, value: 7, to: start)!, wednesday)
    }

    func testWeekStartOnASundayFirstCalendarIsThatWeeksSunday() {
        let sundayFirst = calendar(firstWeekday: 1)
        let start = GridCache.weekStart(of: wednesday, calendar: sundayFirst)
        XCTAssertEqual(sundayFirst.component(.weekday, from: start), 1, "must land on a Sunday")
    }

    func testASundayIsItsOwnWeekStartOnASundayFirstCalendar() {
        let sundayFirst = calendar(firstWeekday: 1)
        XCTAssertEqual(GridCache.weekStart(of: sunday, calendar: sundayFirst), sundayFirst.startOfDay(for: sunday))
    }

    // MARK: - weekdayLabels: only Monday, Wednesday, Friday are named, in the calendar's own row order

    func testWeekdayLabelsOnAMondayFirstCalendarNameRowsZeroTwoFour() {
        let mondayFirst = calendar(firstWeekday: 2)
        let labels = GridCache.weekdayLabels(calendar: mondayFirst)
        let symbols = mondayFirst.shortWeekdaySymbols // always Sun...Sat regardless of firstWeekday
        XCTAssertEqual(labels.count, 7)
        XCTAssertEqual(labels[0], symbols[1], "row 0 is Monday")
        XCTAssertEqual(labels[2], symbols[3], "row 2 is Wednesday")
        XCTAssertEqual(labels[4], symbols[5], "row 4 is Friday")
        for row in [1, 3, 5, 6] {
            XCTAssertEqual(labels[row], "", "row \(row) is blank")
        }
    }

    func testWeekdayLabelsOnASundayFirstCalendarNameRowsOneThreeFive() {
        let sundayFirst = calendar(firstWeekday: 1)
        let labels = GridCache.weekdayLabels(calendar: sundayFirst)
        let symbols = sundayFirst.shortWeekdaySymbols
        XCTAssertEqual(labels[1], symbols[1], "row 1 is Monday")
        XCTAssertEqual(labels[3], symbols[3], "row 3 is Wednesday")
        XCTAssertEqual(labels[5], symbols[5], "row 5 is Friday")
        for row in [0, 2, 4, 6] {
            XCTAssertEqual(labels[row], "", "row \(row) is blank")
        }
    }

    // MARK: - Square colour rules

    func testCellBaseIsGreyForAnUnobservedOrZeroDay() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0, usesStatusColor: true, unobserved: true), .secondary)
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0, usesStatusColor: false, unobserved: false), .secondary)
    }

    func testCellBaseUsesTheAccentForCostAndTheStatusRampForQuota() {
        XCTAssertEqual(ActivityGridView.cellBase(intensity: 0.5, usesStatusColor: false, unobserved: false), .accentColor)
        // A quota square at high utilisation reads the battery colours, not the flat accent.
        XCTAssertNotEqual(ActivityGridView.cellBase(intensity: 0.99, usesStatusColor: true, unobserved: false), .accentColor)
    }

    func testCellOpacityIsAFaintGhostForAnUnobservedDay() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0, unobserved: true), 0.05)
    }

    func testCellOpacityRampsFromTwentyToFullAcrossIntensity() {
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0, unobserved: false), 0.12, "an observed zero is not a ghost")
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 1, unobserved: false), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ActivityGridView.cellOpacity(intensity: 0.5, unobserved: false), 0.60, accuracy: 0.0001)
    }

    // MARK: - retentionNote / statsCaption: the cost grid only (F4/removal ruling)

    func testRetentionNoteIsNilForTheQuotaGridEvenWhenTheCostGridWouldHaveOne() {
        XCTAssertNil(ActivityGridView.retentionNote(provider: "claude", showsQuota: true))
    }

    func testStatsCaptionIsSuppressedForAQuotaGrid() {
        XCTAssertNil(ActivityGridView.statsCaption(isQuota: true, caption: "API-equivalent"))
        XCTAssertEqual(ActivityGridView.statsCaption(isQuota: false, caption: "API-equivalent"), "API-equivalent")
    }

    // MARK: - cellTooltip: dollars get a second line only for a priced day

    func testCellTooltipAddsTheCaptionOnlyForAPricedCostDay() {
        let withCaption = ActivityGridView.cellTooltip("Sep 6: $12.00", hasReading: true, isQuota: false, caption: "API-equivalent")
        XCTAssertEqual(withCaption, "Sep 6: $12.00\nAPI-equivalent")
    }

    func testCellTooltipStaysPlainForAQuotaSquare() {
        let plain = ActivityGridView.cellTooltip("Sep 6: peak 40%", hasReading: true, isQuota: true, caption: "ignored")
        XCTAssertEqual(plain, "Sep 6: peak 40%")
    }

    func testCellTooltipStaysPlainWhenThereIsNoCaption() {
        let plain = ActivityGridView.cellTooltip("Sep 6: $12.00", hasReading: true, isQuota: false, caption: nil)
        XCTAssertEqual(plain, "Sep 6: $12.00")
    }
}
