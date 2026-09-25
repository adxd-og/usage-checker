import XCTest
@testable import Omelette

/// The owner's visual check of 3.0 P1: after a mouse click on "Claude" the yolk ring
/// sat on "Codex". A segment wears the focus ring only while the user navigates the
/// control with the keyboard (`OMFocusRing.isVisible`).
final class OMSegmentedControlKeyboardFocusTests: XCTestCase {
    func testAFocusedSegmentShowsTheRingUnderKeyboardNavigation() {
        XCTAssertTrue(OMSegmentedControl.focusRingVisible(on: "codex", focusedItemID: "codex", keyboardNavigation: true))
    }

    func testFocusAClickLeftBehindDrawsNoRing() {
        XCTAssertFalse(OMSegmentedControl.focusRingVisible(on: "codex", focusedItemID: "codex", keyboardNavigation: false))
        XCTAssertEqual(
            OMSegmentedControl.segmentChrome(
                isSelected: false,
                isFocused: OMSegmentedControl.focusRingVisible(on: "codex", focusedItemID: "codex", keyboardNavigation: false)
            ),
            .plain
        )
    }

    func testOnlyTheFocusedSegmentWearsTheRing() {
        XCTAssertFalse(OMSegmentedControl.focusRingVisible(on: "claude", focusedItemID: "codex", keyboardNavigation: true))
        XCTAssertFalse(OMSegmentedControl.focusRingVisible(on: "claude", focusedItemID: nil, keyboardNavigation: true))
    }

    func testTheSelectedSegmentUnderKeyboardNavigationShowsBoth() {
        XCTAssertEqual(
            OMSegmentedControl.segmentChrome(
                isSelected: true,
                isFocused: OMSegmentedControl.focusRingVisible(on: "claude", focusedItemID: "claude", keyboardNavigation: true)
            ),
            .glassAndRing
        )
    }
}
