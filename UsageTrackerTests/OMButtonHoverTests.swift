import SwiftUI
import XCTest
@testable import Omelette

/// Owner's check of the 3.0 screens (2026-09-25): the popover's, the dashboard's and
/// Settings' buttons (`.omAccent`, `.omCapsule`, `.omCircle`, `.omLink`) drew no hover
/// state, where macOS 26's own controls light up under the pointer. The highlight is a
/// state layer over the control: white in dark, black in light, stronger while pressed,
/// never on a disabled button, fading in and out unless Reduce Motion is on.
final class OMButtonHoverTests: XCTestCase {
    func testAButtonAtRestHasNoHighlight() {
        XCTAssertNil(OMButtonRules.hoverOverlay(isHovered: false, isPressed: false, isEnabled: true, scheme: .dark))
        XCTAssertNil(OMButtonRules.hoverOverlay(isHovered: false, isPressed: false, isEnabled: true, scheme: .light))
    }

    func testHoverLightensADarkButton() {
        XCTAssertEqual(
            OMButtonRules.hoverOverlay(isHovered: true, isPressed: false, isEnabled: true, scheme: .dark),
            .white(0.08)
        )
    }

    func testHoverDarkensALightButton() {
        XCTAssertEqual(
            OMButtonRules.hoverOverlay(isHovered: true, isPressed: false, isEnabled: true, scheme: .light),
            .black(0.05)
        )
    }

    func testPressingIsStrongerThanHovering() {
        XCTAssertEqual(
            OMButtonRules.hoverOverlay(isHovered: true, isPressed: true, isEnabled: true, scheme: .dark),
            .white(0.14)
        )
        XCTAssertEqual(
            OMButtonRules.hoverOverlay(isHovered: true, isPressed: true, isEnabled: true, scheme: .light),
            .black(0.10)
        )
    }

    /// A press the pointer has already left (dragged off before release) still shows as
    /// pressed until it ends.
    func testAPressWithoutHoverStillShowsPressed() {
        XCTAssertEqual(
            OMButtonRules.hoverOverlay(isHovered: false, isPressed: true, isEnabled: true, scheme: .dark),
            .white(0.14)
        )
    }

    func testADisabledButtonNeverLightsUp() {
        for scheme in [ColorScheme.dark, .light] {
            XCTAssertNil(OMButtonRules.hoverOverlay(isHovered: true, isPressed: false, isEnabled: false, scheme: scheme))
            XCTAssertNil(OMButtonRules.hoverOverlay(isHovered: true, isPressed: true, isEnabled: false, scheme: scheme))
        }
    }

    func testTheHighlightFadesInATenthOfASecondAndABit() {
        XCTAssertEqual(OMButtonRules.hoverFade(reduceMotion: false), 0.12)
    }

    func testReduceMotionSwitchesTheHighlightWithoutAFade() {
        XCTAssertNil(OMButtonRules.hoverFade(reduceMotion: true))
    }

    /// A link has no chrome of its own: its highlight is a capsule a little larger than
    /// its words, drawn without moving them.
    func testALinksHighlightReachesJustPastItsWords() {
        XCTAssertEqual(OMButtonRules.linkHoverOutset, CGSize(width: 6, height: 3))
    }

    /// Sidebar items and segments (owner's check, 2026-09-25: the dashboard's and
    /// Settings' sidebars and segmented controls drew no hover): an item the pointer can
    /// still choose lights up like any button.
    func testAnUnselectedItemLightsUpUnderThePointer() {
        XCTAssertTrue(OMButtonRules.showsHoverWhenSelectable(isSelected: false))
    }

    /// The selected item is already the raised pill; the pointer over it has nothing to
    /// choose, so it stays still.
    func testTheSelectedItemStaysStill() {
        XCTAssertFalse(OMButtonRules.showsHoverWhenSelectable(isSelected: true))
    }
}
