import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Principles 1 (glass on the popover body), § Tokens
/// ("popover 24", chrome glass, window background: "popover body"). `Main.dc.html`:
/// 360 pt wide, 14 pt in, 12 pt between sections; a 30 pt icon, a 14 pt title, an
/// 11.5 pt meta line.
final class PopoverBodyTests: XCTestCase {
    func testThePopoverIsThreeSixtyWideWithFourteenPointInsets() {
        XCTAssertEqual(PopoverView.width, 360)
        XCTAssertEqual(PopoverView.padding, 14)
        XCTAssertEqual(PopoverView.spacing, 12)
    }

    func testTheBodyIsChromeGlassWithTheTwentyFourPointCorner() {
        XCTAssertEqual(PopoverView.bodyGlass, .chrome)
        XCTAssertEqual(OMRadius.corner(for: PopoverView.bodyCorner), .rounded(24))
    }

    func testTheHeaderIsTheMockups() {
        XCTAssertEqual(PopoverView.appIconSize, 30)
        XCTAssertEqual(PopoverView.appIconSpacing, 10)
        XCTAssertEqual(PopoverView.titleSize, 14)
        XCTAssertEqual(PopoverView.metaSize, 11.5)
    }

    func testTheCannotRefreshNoticeIsAmber() {
        XCTAssertEqual(PopoverView.staleNoticeToken, .warning)
    }
}
