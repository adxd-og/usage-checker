import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Components, "Segmented controls": "glass
/// capsule track; selected segment is a raised glass pill, not accent blue". The
/// title rule (`OMSegmentedControlTitleRuleTests`) and the selection/focus rule
/// (`OMSegmentedControlFocusTests`) are unchanged; this pins the new look.
final class OMSegmentedControlLookTests: XCTestCase {
    func testTheTrackIsTintedSystemGlass() {
        XCTAssertEqual(OMSegmentedControl.trackSurface, .controlTrack)
        XCTAssertTrue(OMGlassRules.usesSystemGlass(OMSegmentedControl.trackSurface))
    }

    func testTheSelectedSegmentIsARaisedPillNotASecondLayerOfGlass() {
        XCTAssertEqual(OMSegmentedControl.selectedSurface, .raisedPill)
        XCTAssertFalse(OMGlassRules.usesSystemGlass(OMSegmentedControl.selectedSurface))
    }

    func testTheSelectedLabelReadsInTheTextColourAndTheOthersInSecondary() {
        XCTAssertEqual(OMSegmentedControl.labelToken(isSelected: true), .text)
        XCTAssertEqual(OMSegmentedControl.labelToken(isSelected: false), .secondary)
    }

    func testKeyboardFocusIsTheYolkRingNotTheSystemAccent() {
        XCTAssertEqual(OMSegmentedControl.focusRingToken, .focusRing)
    }
}
