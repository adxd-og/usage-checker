import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Components, "Sidebar": "selected item is a
/// glass pill with accent icon". Metrics from `Dashboard-Overview(-Light).dc.html`:
/// 34 pt rows, 12 pt side padding, 10 pt icon gap, 13 pt type, radius 11.
final class OMSidebarPillTests: XCTestCase {
    func testTheSelectedItemIsARaisedPillWithAnAccentIconAndATextTitle() {
        XCTAssertEqual(OMSidebarPillRules.appearance(isSelected: true), OMSidebarPillAppearance(
            showsPill: true, title: .text, icon: .accentText, weight: .semibold))
    }

    func testAnUnselectedItemHasNoPillAndReadsInSecondary() {
        XCTAssertEqual(OMSidebarPillRules.appearance(isSelected: false), OMSidebarPillAppearance(
            showsPill: false, title: .secondary, icon: .secondary, weight: .medium))
    }

    func testTheSelectedIconIsYolkInDarkAndTheDeeperMixInLight() {
        let icon = OMSidebarPillRules.appearance(isSelected: true).icon
        XCTAssertEqual(OMPalette.rgba(icon, scheme: .dark), OMRGBA(hex: 0xF2B544))
        XCTAssertEqual(OMPalette.rgba(icon, scheme: .light), OMRGBA(hex: 0x846739))
    }

    func testTheItemMetricsAreTheMockups() {
        XCTAssertEqual(OMSidebarPillRules.height, 34)
        XCTAssertEqual(OMSidebarPillRules.horizontalPadding, 12)
        XCTAssertEqual(OMSidebarPillRules.iconSpacing, 10)
        XCTAssertEqual(OMSidebarPillRules.fontSize, 13)
        XCTAssertEqual(OMRadius.corner(for: .navItem), .rounded(11))
    }
}
