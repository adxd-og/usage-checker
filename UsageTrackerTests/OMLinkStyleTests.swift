import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Design → Components, "Links": "accent text + chevron,
/// no button chrome ("History ›", "Show all 103")". Values from
/// `Dashboard-Overview(-Light).dc.html`: 12.5 pt semibold, 2 pt before the chevron.
final class OMLinkStyleTests: XCTestCase {
    func testALinkReadsInTheAccentAsText() {
        XCTAssertEqual(OMLinkRules.textToken, .accentText)
        XCTAssertEqual(OMPalette.rgba(OMLinkRules.textToken, scheme: .dark), OMRGBA(hex: 0xF2B544))
        XCTAssertEqual(OMPalette.rgba(OMLinkRules.textToken, scheme: .light), OMRGBA(hex: 0x846739))
    }

    func testALinkEndsInAChevron() {
        XCTAssertEqual(OMLinkRules.chevronSymbol, "chevron.right")
    }

    func testTheLinkTypeIsTheMockups() {
        XCTAssertEqual(OMLinkRules.fontSize, 12.5)
        XCTAssertEqual(OMLinkRules.spacing, 2)
        XCTAssertEqual(OMLinkRules.chevronSize, 9)
    }
}
