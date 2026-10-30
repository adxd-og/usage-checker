import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (tokens: padding 14, titles 13, secondary 11.5) and
/// the liquid-glass spec § Tokens ("popover 24", chrome glass): the island's content is
/// inset 14 pt; the strip beside the camera says "Omelette" at 13 pt over an 11.5 pt meta
/// line; the panel keeps the chrome glass body in the 24 pt corner.
final class PopoverBodyTests: XCTestCase {
    func testTheContentIsInsetFourteenPoints() {
        XCTAssertEqual(PopoverView.padding, 14)
        XCTAssertEqual(PopoverView.padding, ProviderGridRules.padding)
    }

    func testThePanelsBodyIsChromeGlassWithTheTwentyFourPointCorner() {
        XCTAssertEqual(PopoverView.bodyGlass, .chrome)
        XCTAssertEqual(OMRadius.corner(for: PopoverView.bodyCorner), .rounded(24))
    }

    func testTheStripIsAThirteenPointTitleAndAnElevenAndAHalfPointMetaLine() {
        XCTAssertEqual(PopoverView.stripTitleSize, 13)
        XCTAssertEqual(PopoverView.metaSize, 11.5)
        XCTAssertEqual(PopoverView.stripNotchGap, 10)
    }

    func testTheCannotRefreshNoticeIsAmber() {
        XCTAssertEqual(PopoverView.staleNoticeToken, .warning)
    }
}
