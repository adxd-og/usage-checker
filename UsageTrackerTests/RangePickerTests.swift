import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Segmented controls", and § Packages P2: the
/// dashboard's range picker is the glass capsule, one short-named segment per range.
final class RangePickerTests: XCTestCase {
    func testEachRangeIsASegmentTitledWithItsShortName() {
        XCTAssertEqual(RangePicker.items(for: [.oneDay, .sevenDays, .ninetyDays]), [
            OMSegmentItem(id: "24h", title: "24h"),
            OMSegmentItem(id: "7d", title: "7d"),
            OMSegmentItem(id: "90d", title: "90d"),
        ])
    }

    func testARangeSegmentCarriesNoLogoSoItAlwaysKeepsItsWord() {
        XCTAssertTrue(RangePicker.items(for: TimeRange.allCases).allSatisfy { $0.serviceID == nil })
    }

    func testPickingASegmentPicksItsRange() {
        XCTAssertEqual(RangePicker.timeRange(forSegment: "30d", current: .sevenDays), .thirtyDays)
        XCTAssertEqual(RangePicker.timeRange(forSegment: "5h", current: .sevenDays), .fiveHours)
    }

    func testASegmentIdNoRangeAnswersToChangesNothing() {
        XCTAssertEqual(RangePicker.timeRange(forSegment: "1w", current: .thirtyDays), .thirtyDays)
    }

    func testVoiceOverCallsItTheTimeRange() {
        XCTAssertEqual(RangePicker.accessibilityName, "Time range")
    }

    func testAYearIsTheLastRangeAndTitledOneY() {
        XCTAssertEqual(TimeRange.allCases.last, .oneYear)
        XCTAssertEqual(RangePicker.items(for: [.oneYear]), [OMSegmentItem(id: "1y", title: "1y")])
        XCTAssertEqual(RangePicker.timeRange(forSegment: "1y", current: .sevenDays), .oneYear)
    }

    func testAYearIs365Days() {
        XCTAssertEqual(TimeRange.oneYear.seconds, 365 * 24 * 3600)
    }
}
