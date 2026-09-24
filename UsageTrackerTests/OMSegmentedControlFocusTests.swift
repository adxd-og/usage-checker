import XCTest
@testable import Omelette

/// A segment has two independent looks: the glass capsule for the selected one and an
/// accent ring for the one keyboard focus is on. In the dashboard ⌘1…⌘9 belong to the
/// sidebar, so Tab is the only way through the provider row, and with
/// `.focusEffectDisabled()` that focus was invisible. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — Keyboard; report D § 4.
final class OMSegmentedControlFocusTests: XCTestCase {
    func testAnUnselectedUnfocusedSegmentWearsNothing() {
        XCTAssertEqual(OMSegmentedControl.segmentChrome(isSelected: false, isFocused: false), .plain)
    }

    func testKeyboardFocusAloneDrawsTheRing() {
        XCTAssertEqual(OMSegmentedControl.segmentChrome(isSelected: false, isFocused: true), .focusRing)
    }

    func testSelectionAloneIsTheGlassCapsule() {
        XCTAssertEqual(OMSegmentedControl.segmentChrome(isSelected: true, isFocused: false), .glass)
    }

    func testTheSelectedSegmentShowsFocusToo() {
        XCTAssertEqual(OMSegmentedControl.segmentChrome(isSelected: true, isFocused: true), .glassAndRing)
    }

    func testEachLookDrawsExactlyWhatItsNameSays() {
        XCTAssertFalse(SegmentChrome.plain.showsGlass)
        XCTAssertFalse(SegmentChrome.plain.showsFocusRing)
        XCTAssertFalse(SegmentChrome.focusRing.showsGlass)
        XCTAssertTrue(SegmentChrome.focusRing.showsFocusRing)
        XCTAssertTrue(SegmentChrome.glass.showsGlass)
        XCTAssertFalse(SegmentChrome.glass.showsFocusRing)
        XCTAssertTrue(SegmentChrome.glassAndRing.showsGlass)
        XCTAssertTrue(SegmentChrome.glassAndRing.showsFocusRing)
    }
}
