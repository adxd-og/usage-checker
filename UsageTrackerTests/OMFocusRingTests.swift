import SwiftUI
import XCTest
@testable import Omelette

/// The macOS convention the owner's visual check of 3.0 P1 asked for: a focus ring shows
/// only while the user navigates with the keyboard. A control that holds focus because of
/// a click, or keeps it after one, draws no ring.
final class OMFocusRingTests: XCTestCase {
    func testTheRingShowsOnlyWhenFocusedUnderKeyboardNavigation() {
        XCTAssertTrue(OMFocusRing.isVisible(isFocused: true, keyboardNavigation: true))
        XCTAssertFalse(OMFocusRing.isVisible(isFocused: true, keyboardNavigation: false))
        XCTAssertFalse(OMFocusRing.isVisible(isFocused: false, keyboardNavigation: true))
        XCTAssertFalse(OMFocusRing.isVisible(isFocused: false, keyboardNavigation: false))
    }

    func testTabAndTheArrowsAreKeyboardNavigation() {
        XCTAssertEqual(OMFocusRing.navigationKeys, [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow])
        XCTAssertFalse(OMFocusRing.navigationKeys.contains(.return))
        XCTAssertFalse(OMFocusRing.navigationKeys.contains(.space))
    }

    /// Tab into a control from outside it is seen by the control only as its focus
    /// arriving: a key press moved it there, so the ring shows. A click that moved focus
    /// (or removed it) is not keyboard navigation.
    func testFocusThatAKeyPressMovedInIsKeyboardNavigation() {
        XCTAssertTrue(OMFocusRing.keyboardNavigation(afterFocusMovedTo: true, byKeyPress: true))
        XCTAssertFalse(OMFocusRing.keyboardNavigation(afterFocusMovedTo: true, byKeyPress: false))
        XCTAssertFalse(OMFocusRing.keyboardNavigation(afterFocusMovedTo: false, byKeyPress: true))
        XCTAssertFalse(OMFocusRing.keyboardNavigation(afterFocusMovedTo: false, byKeyPress: false))
    }
}
