import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 2 and § 3.1 (Display and anchor): the camera housing is
/// read live from the display, as tall as the top safe area and as wide as the two menu bar
/// areas beside it leave (P0's method), in global coordinates.
final class IslandScreenTests: XCTestCase {
    private func screen(
        x: CGFloat = 0, width: CGFloat = 1512, height: CGFloat = 982,
        top: CGFloat = 32, left: CGFloat? = 663.5, right: CGFloat? = 663.5
    ) -> IslandScreen {
        IslandScreen(
            id: 1,
            frame: CGRect(x: x, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: x, y: 78, width: width, height: height - top - 78),
            safeAreaTop: top,
            auxiliaryLeftWidth: left,
            auxiliaryRightWidth: right
        )
    }

    func testThe14InchNotchIs185By32AtTheTopCentre() {
        XCTAssertEqual(screen().notchRect, CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    func testTheNotchIsReadFromTheDisplayModeNotAFixedSize() {
        XCTAssertEqual(
            screen(width: 1800, height: 1169, left: 820, right: 820).notchRect,
            CGRect(x: 820, y: 1137, width: 160, height: 32)
        )
    }

    func testANotchedDisplayLeftOfTheMainOneKeepsItsNegativeX() {
        XCTAssertEqual(screen(x: -1512).notchRect, CGRect(x: -848.5, y: 950, width: 185, height: 32))
    }

    func testNoTopSafeAreaMeansNoNotch() {
        XCTAssertNil(screen(top: 0).notchRect)
    }

    func testMissingOrEmptyMenuBarAreasMeanNoNotch() {
        XCTAssertNil(screen(left: nil).notchRect)
        XCTAssertNil(screen(right: nil).notchRect)
        XCTAssertNil(screen(left: 0).notchRect)
    }

    func testMenuBarAreasThatLeaveNoRoomMeanNoNotch() {
        XCTAssertNil(screen(left: 756, right: 756).notchRect)
    }

    func testHasNotchFollowsTheRect() {
        XCTAssertTrue(screen().hasNotch)
        XCTAssertFalse(screen(top: 0).hasNotch)
    }

    /// Spec 2026-11-03 § Virtual notch: what the visible frame leaves at the top, 0 when the menu
    /// bar is hidden there.
    func testTheMenuBarHeightIsWhatTheVisibleFrameLeavesAtTheTop() {
        XCTAssertEqual(ScreenFixture.builtIn.menuBarHeight, 32)
        XCTAssertEqual(ScreenFixture.narrowNotched.menuBarHeight, 34)
        XCTAssertEqual(ScreenFixture.externalRight.menuBarHeight, 24)
        XCTAssertEqual(ScreenFixture.externalRightMenuBarHidden.menuBarHeight, 0)
    }
}
