import XCTest
@testable import Omelette

/// Whether a segment keeps its name is the control's only real decision — five
/// icons plus five words do not fit the popover's 360 pt, while the dashboard
/// header has room to spare. Pulled out of the view so both answers are pinned
/// without a hosting window.
final class OMSegmentedControlTitleRuleTests: XCTestCase {
    func testFourOrFewerSegmentsKeepTheirNames() {
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 1, alwaysShowsTitles: false))
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 4, alwaysShowsTitles: false))
    }

    func testAFifthSegmentDropsTheNames() {
        // The popover's rule today, unchanged: All + five providers is icon-only.
        XCTAssertFalse(OMSegmentedControl.showsTitles(count: 5, alwaysShowsTitles: false))
        XCTAssertFalse(OMSegmentedControl.showsTitles(count: 9, alwaysShowsTitles: false))
    }

    func testTheDashboardKeepsTheNamesAtAnyCount() {
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 5, alwaysShowsTitles: true))
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 12, alwaysShowsTitles: true))
    }

    func testAnEmptyRowIsHarmlessRatherThanACrash() {
        XCTAssertTrue(OMSegmentedControl.showsTitles(count: 0, alwaysShowsTitles: false))
    }
}
