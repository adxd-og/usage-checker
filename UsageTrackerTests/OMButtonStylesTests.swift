import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Principles 1–2: glass on buttons, and "the only filled
/// control is the primary action (Allow)". Values from `Main.dc.html`: Allow and Deny
/// 28 pt, the footer's buttons 32 pt.
final class OMButtonStylesTests: XCTestCase {
    func testAllowIsTheYolkFillWithADarkLabelAndATopLight() {
        XCTAssertEqual(OMButtonRules.accentFill, .accent)
        XCTAssertEqual(OMButtonRules.accentLabel, .onAccent)
        XCTAssertEqual(OMButtonRules.accentHighlight, .white(0.45))
    }

    func testEveryOtherButtonStandsOnTheControlTrackGlass() {
        XCTAssertEqual(OMButtonRules.capsuleSurface, .controlTrack)
        XCTAssertEqual(OMButtonRules.capsuleLabel, .text)
    }

    func testRowButtonsAreTwentyEightPointsAndFooterButtonsThirtyTwo() {
        XCTAssertEqual(OMButtonRules.height(.small), 28)
        XCTAssertEqual(OMButtonRules.height(.regular), 32)
    }

    func testPaddingsAreTheMockups() {
        XCTAssertEqual(OMButtonRules.leadingPadding(.small, accent: true), 18)
        XCTAssertEqual(OMButtonRules.trailingPadding(.small, accent: true), 18)
        XCTAssertEqual(OMButtonRules.leadingPadding(.small, accent: false), 16)
        XCTAssertEqual(OMButtonRules.trailingPadding(.small, accent: false), 16)
        XCTAssertEqual(OMButtonRules.leadingPadding(.regular, accent: false), 12)
        XCTAssertEqual(OMButtonRules.trailingPadding(.regular, accent: false), 14)
    }

    func testTypeAndIconSizes() {
        XCTAssertEqual(OMButtonRules.fontSize, 12.5)
        XCTAssertEqual(OMButtonRules.iconSize, 15)
        XCTAssertEqual(OMButtonRules.iconSpacing, 7)
    }
}
