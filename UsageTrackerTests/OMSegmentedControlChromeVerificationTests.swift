import XCTest
@testable import Omelette

/// Independent verification of `OMSegmentedControl.segmentChrome(isSelected:isFocused:)`,
/// from the spec rather than from the executor's own `OMSegmentedControlFocusTests`.
/// Spec: docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session
/// rulings), UI — "`OMSegmentedControl` draws a `strokeBorder(Color.accentColor)`
/// capsule for the focused item (`segmentChrome(isSelected:isFocused:)` rule)";
/// report D § 4. Claim under test: all four focus/selection combinations produce
/// distinct chrome and only the focused ones carry a ring.
final class OMSegmentedControlChromeVerificationTests: XCTestCase {
    func testAllFourCombinationsAreDistinct() {
        let combos: [(Bool, Bool)] = [(false, false), (false, true), (true, false), (true, true)]
        let results = combos.map { OMSegmentedControl.segmentChrome(isSelected: $0.0, isFocused: $0.1) }
        XCTAssertEqual(Set(results).count, 4, "each of the four combinations must draw its own chrome: \(results)")
    }

    func testOnlyTheTwoFocusedCombinationsShowARing() {
        let cases: [(isSelected: Bool, isFocused: Bool, expectsRing: Bool)] = [
            (false, false, false),
            (true, false, false),
            (false, true, true),
            (true, true, true),
        ]
        for c in cases {
            let chrome = OMSegmentedControl.segmentChrome(isSelected: c.isSelected, isFocused: c.isFocused)
            XCTAssertEqual(
                chrome.showsFocusRing, c.expectsRing,
                "isSelected=\(c.isSelected) isFocused=\(c.isFocused) -> \(chrome)"
            )
        }
    }

    func testGlassTracksSelectionIndependentlyOfFocus() {
        XCTAssertTrue(OMSegmentedControl.segmentChrome(isSelected: true, isFocused: false).showsGlass)
        XCTAssertTrue(OMSegmentedControl.segmentChrome(isSelected: true, isFocused: true).showsGlass)
        XCTAssertFalse(OMSegmentedControl.segmentChrome(isSelected: false, isFocused: false).showsGlass)
        XCTAssertFalse(OMSegmentedControl.segmentChrome(isSelected: false, isFocused: true).showsGlass)
    }

    func testAnUnselectedUnfocusedSegmentShowsNeitherGlassNorRing() {
        let chrome = OMSegmentedControl.segmentChrome(isSelected: false, isFocused: false)
        XCTAssertFalse(chrome.showsGlass)
        XCTAssertFalse(chrome.showsFocusRing)
    }

    func testTheSelectedAndFocusedSegmentShowsBoth() {
        let chrome = OMSegmentedControl.segmentChrome(isSelected: true, isFocused: true)
        XCTAssertTrue(chrome.showsGlass)
        XCTAssertTrue(chrome.showsFocusRing)
    }

    /// The rule must be a pure function of its two flags — calling it repeatedly with
    /// the same arguments must be idempotent.
    func testTheRuleIsDeterministic() {
        for isSelected in [false, true] {
            for isFocused in [false, true] {
                let a = OMSegmentedControl.segmentChrome(isSelected: isSelected, isFocused: isFocused)
                let b = OMSegmentedControl.segmentChrome(isSelected: isSelected, isFocused: isFocused)
                XCTAssertEqual(a, b)
            }
        }
    }
}
