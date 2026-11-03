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

    /// Spec 2026-11-03 § Virtual notch: without a measurement, what the visible frame leaves at the
    /// top, 0 when the menu bar is hidden there.
    func testTheMenuBarHeightIsWhatTheVisibleFrameLeavesAtTheTop() {
        XCTAssertEqual(ScreenFixture.builtIn.menuBarHeight, 32)
        XCTAssertEqual(ScreenFixture.narrowNotched.menuBarHeight, 34)
        XCTAssertEqual(ScreenFixture.externalRight.menuBarHeight, 24)
        XCTAssertEqual(ScreenFixture.externalRightMenuBarHidden.menuBarHeight, 0)
    }

    // MARK: - The island's notch (spec 2026-11-03 § Virtual notch)

    func testANotchedDisplaysIslandNotchIsItsCameraHousing() {
        XCTAssertEqual(ScreenFixture.builtIn.islandNotch, ScreenFixture.builtIn.notchRect)
        XCTAssertEqual(ScreenFixture.narrowNotched.islandNotch, CGRect(x: 580, y: 844, width: 192, height: 34))
    }

    func testADisplayWithoutANotchGetsAVirtualOneAndStillHasNoNotch() {
        XCTAssertEqual(ScreenFixture.externalRight.islandNotch, CGRect(x: 2699.5, y: 1416, width: 185, height: 24))
        XCTAssertNil(ScreenFixture.externalRight.notchRect)
        XCTAssertFalse(ScreenFixture.externalRight.hasNotch, "hasNotch is the camera housing")
    }

    func testDisplaysReadTogetherTakeTheNotchedDisplaysWidth() {
        let screens = IslandScreen.attached([ScreenFixture.narrowNotched, ScreenFixture.externalRight])
        XCTAssertEqual(screens.map(\.id), [4, 2], "the order is kept")
        XCTAssertEqual(screens.map(\.referenceNotchWidth), [192, 192])
        XCTAssertEqual(screens[1].islandNotch, CGRect(x: 2696, y: 1416, width: 192, height: 24))
        XCTAssertEqual(screens[0].islandNotch, ScreenFixture.narrowNotched.notchRect, "the notched display keeps its own")
    }

    /// The lid closed, or a Mac without a notch: nothing to match, so 185.
    func testWithNoNotchedDisplayAttachedThePillIs185Wide() {
        let screens = IslandScreen.attached([ScreenFixture.externalRight, ScreenFixture.externalLeft])
        XCTAssertEqual(screens.map(\.referenceNotchWidth), [nil, nil])
        XCTAssertEqual(screens.compactMap(\.islandNotch).map(\.width), [185, 185])
    }

    func testNoIslandNotchOnANarrowDisplayOrUnderAHiddenMenuBar() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.narrow1279, ScreenFixture.externalLeftMenuBarHidden]
        )
        XCTAssertNotNil(screens[0].islandNotch)
        XCTAssertNil(screens[1].islandNotch)
        XCTAssertNil(screens[2].islandNotch)
    }

    // MARK: - The measured menu bar (spec 2026-11-03, Amendment after the spike)

    func testAReadingWithoutAMeasurementKeepsTheVisibleFramesAnswer() {
        XCTAssertNil(ScreenFixture.externalRight.measuredMenuBarHeight)
        XCTAssertEqual(ScreenFixture.externalRight.menuBarHeight, 24)
        XCTAssertEqual(IslandScreen.attached([ScreenFixture.externalRight]).map(\.menuBarHeight), [24])
    }

    func testAMeasuredHeightWinsOverTheVisibleFrame() {
        var screen = ScreenFixture.externalRight
        screen.measuredMenuBarHeight = 30
        XCTAssertEqual(screen.menuBarHeight, 30)
        screen.measuredMenuBarHeight = 0
        XCTAssertEqual(screen.menuBarHeight, 0, "a menu bar measured absent stays absent")
        XCTAssertNil(screen.islandNotch)
    }

    /// Setup 1: 2560 wide from x 1512, centre 2792; top 982, menu bar 30, so 952–982.
    func testASecondaryExternalGetsItsPillFromItsMenuBarWindow() {
        XCTAssertNil(ScreenFixture.secondaryExternal.islandNotch, "its visible frame alone gives no pill")
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        XCTAssertEqual(screens.map(\.id), [1, 2], "the order is kept")
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [33, 30])
        XCTAssertEqual(screens.map(\.referenceNotchWidth), [185, 185], "the notch width is still carried")
        XCTAssertEqual(screens[1].islandNotch, CGRect(x: 2699.5, y: 952, width: 185, height: 30))
        XCTAssertEqual(screens[1].islandNotch, VirtualNotchRules.rect(screen: screens[1], referenceNotchWidth: 185))
        XCTAssertEqual(screens[0].islandNotch, ScreenFixture.builtIn.notchRect, "the built-in keeps its camera housing")
    }

    /// Full screen on the external, or its menu bar hidden: no window there, no pill.
    func testWithoutItsMenuBarWindowTheExternalGetsNoPill() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal], menuBarWindows: [MenuBarWindowFixture.builtIn]
        )
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [33, 0])
        XCTAssertNil(screens[1].islandNotch)
    }

    func testAMeasuredReadingWithNoMenuBarWindowOverridesWhatTheVisibleFrameLeaves() {
        let screens = IslandScreen.attached([ScreenFixture.externalRight], menuBarWindows: [])
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [0])
        XCTAssertNil(screens[0].islandNotch)
    }

    /// The first display is the main one, the origin of both coordinate systems: here 1440 tall.
    func testWithTheLidClosedTheWindowsAreMeasuredFromTheExternalAsMain() {
        let screens = IslandScreen.attached(
            [ScreenFixture.lidClosedExternal], menuBarWindows: [MenuBarWindowFixture.lidClosedExternal]
        )
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [30])
        XCTAssertEqual(screens[0].islandNotch, CGRect(x: 1187.5, y: 1410, width: 185, height: 30))
    }
}
