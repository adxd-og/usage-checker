import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Principles 3: "Sentence-case section titles, no
/// uppercase micro labels". `Main.dc.html` ("Agents · 3 live") and `Popover-Claude.dc.html`
/// ("Weekly limits · resets …"): a 13 pt title in the text colour, an 11.5 pt caption
/// in secondary. The view applies no text case.
final class OMSectionHeaderTests: XCTestCase {
    func testTheTitleIsThirteenPointTextNotAMicroLabel() {
        XCTAssertEqual(OMSectionHeader.titleSize, 13)
        XCTAssertEqual(OMSectionHeader.titleToken, .text)
    }

    func testTheCaptionIsSecondaryOnTheSameLine() {
        XCTAssertEqual(OMSectionHeader.trailingSize, 11.5)
        XCTAssertEqual(OMSectionHeader.trailingToken, .secondary)
    }
}
