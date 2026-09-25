import XCTest
@testable import Omelette

/// The dashboard sidebar follows the same macOS convention as the segmented controls: an
/// item wears the yolk focus ring only while the user navigates with the keyboard
/// (`OMFocusRing.isVisible`), not because a click left focus on it.
final class DashboardSidebarFocusTests: XCTestCase {
    func testAFocusedItemShowsTheRingUnderKeyboardNavigation() {
        XCTAssertTrue(DashboardSidebarRules.focusRingVisible(on: .history, focusedTab: .history, keyboardNavigation: true))
    }

    func testFocusAClickLeftBehindDrawsNoRing() {
        XCTAssertFalse(DashboardSidebarRules.focusRingVisible(on: .history, focusedTab: .history, keyboardNavigation: false))
    }

    func testOnlyTheFocusedItemWearsTheRing() {
        XCTAssertFalse(DashboardSidebarRules.focusRingVisible(on: .overview, focusedTab: .history, keyboardNavigation: true))
        XCTAssertFalse(DashboardSidebarRules.focusRingVisible(on: .overview, focusedTab: nil, keyboardNavigation: true))
    }
}
