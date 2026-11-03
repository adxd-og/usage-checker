import CoreGraphics
import XCTest
@testable import Omelette

/// Spec 2026-11-03, Amendment after the spike: each display's menu bar height is the WindowServer's
/// menu bar window along its top (owner "Window Server", layer 24), 0 without one. These cover the
/// CG-to-AppKit flip for displays in every arrangement, decoys, and the reading `attached` makes.
final class MenuBarWindowRulesVerificationTests: XCTestCase {
    private func display(id: UInt32, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> IslandScreen {
        IslandScreen(
            id: id,
            frame: CGRect(x: x, y: y, width: width, height: height),
            visibleFrame: CGRect(x: x, y: y, width: width, height: height),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
    }

    private func window(_ bounds: CGRect, owner: String = "Window Server", layer: Int = 24) -> MenuBarWindow {
        MenuBarWindow(ownerName: owner, layer: layer, boundsCG: bounds)
    }

    private func heights(_ windows: [MenuBarWindow], _ screens: [IslandScreen], main: CGFloat) -> [UInt32: CGFloat] {
        MenuBarWindowRules.heights(windows: windows, screens: screens, mainDisplayHeight: main)
    }

    // MARK: - Arrangements: the flip from CG (y down from the main display's top) to AppKit

    /// Main 1512 x 982 at the origin; an external right under it, its AppKit top at y = 0, so CG y = 982.
    func testADisplayRightUnderTheMainOneMatchesAWindowAtCGYOfTheMainsHeight() {
        let main = display(id: 1, x: 0, y: 0, width: 1512, height: 982)
        let below = display(id: 2, x: 0, y: -1440, width: 2560, height: 1440)
        let bar = window(CGRect(x: 0, y: 982, width: 2560, height: 30))
        XCTAssertEqual(heights([bar], [main, below], main: 982), [1: 0, 2: 30])
    }

    /// The same, spelled out: the lower display's top edge is AppKit y 0 only when it hangs from it; a
    /// display whose top is at AppKit -100 is at CG 1082.
    func testADisplayBelowTheMainOneMatchesItsOwnTopNotTheMains() {
        let main = display(id: 1, x: 0, y: 0, width: 1512, height: 982)
        let below = display(id: 2, x: 0, y: -1540, width: 2560, height: 1440) // top at AppKit -100
        let belowBar = window(CGRect(x: 0, y: 1082, width: 2560, height: 30))
        let mainBar = window(CGRect(x: 0, y: 0, width: 1512, height: 33))
        XCTAssertEqual(heights([belowBar], [main, below], main: 982), [1: 0, 2: 30])
        XCTAssertEqual(heights([mainBar], [main, below], main: 982), [1: 33, 2: 0])
        XCTAssertEqual(heights([mainBar, belowBar], [main, below], main: 982), [1: 33, 2: 30])
    }

    /// A display to the left whose top sits above the main display's: AppKit top 1280 is CG y -298.
    func testADisplayToTheLeftAndHigherMatchesANegativeCGY() {
        let main = display(id: 1, x: 0, y: 0, width: 1512, height: 982)
        let left = display(id: 3, x: -1920, y: 200, width: 1920, height: 1080)
        let leftBar = window(CGRect(x: -1920, y: -298, width: 1920, height: 24))
        XCTAssertEqual(heights([leftBar], [main, left], main: 982), [1: 0, 3: 24])
    }

    /// The same left display, lower than the main one: AppKit top 500 is CG y 482.
    func testADisplayToTheLeftAndLowerMatchesAPositiveCGY() {
        let main = display(id: 1, x: 0, y: 0, width: 1512, height: 982)
        let left = display(id: 3, x: -1920, y: -580, width: 1920, height: 1080)
        let leftBar = window(CGRect(x: -1920, y: 482, width: 1920, height: 24))
        XCTAssertEqual(heights([leftBar], [main, left], main: 982), [1: 0, 3: 24])
    }

    /// A window put where the unflipped (AppKit-spelled) top would be belongs to no display.
    func testAWindowInAppKitCoordinatesIsNotAMenuBar() {
        let main = display(id: 1, x: 0, y: 0, width: 1512, height: 982)
        let ext = display(id: 2, x: 1512, y: -458, width: 2560, height: 1440)
        let notFlipped = window(CGRect(x: 1512, y: 952, width: 2560, height: 30))
        XCTAssertEqual(heights([notFlipped], [main, ext], main: 982), [1: 0, 2: 0])
    }

    /// The main display's height is the flip's pivot: the same window reads against 1440 and 982.
    func testTheMainDisplaysHeightIsWhatTheFlipTurnsOn() {
        let ext = display(id: 2, x: 0, y: 0, width: 2560, height: 1440)
        let bar = window(CGRect(x: 0, y: 0, width: 2560, height: 30))
        XCTAssertEqual(heights([bar], [ext], main: 1440), [2: 30])
        XCTAssertEqual(heights([bar], [ext], main: 982), [2: 0])
    }

    /// The external as the main display, the MacBook beside it as the secondary, tops level at 1440.
    func testTheMacBookAsASecondaryDisplayHasItsOwnWindowRead() {
        let main = display(id: 2, x: 0, y: 0, width: 2560, height: 1440)
        let book = display(id: 1, x: 2560, y: 458, width: 1512, height: 982)
        let mainBar = window(CGRect(x: 0, y: 0, width: 2560, height: 30))
        let bookBar = window(CGRect(x: 2560, y: 0, width: 1512, height: 33))
        XCTAssertEqual(heights([mainBar, bookBar], [main, book], main: 1440), [2: 30, 1: 33])
        XCTAssertEqual(heights([bookBar], [main, book], main: 1440), [2: 0, 1: 33])
    }

    // MARK: - What decides which display

    func testTheFirstMatchingWindowGivesTheHeight() {
        let screens = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]
        let first = window(CGRect(x: 1512, y: 0, width: 2560, height: 30))
        let second = window(CGRect(x: 1512, y: 0, width: 2560, height: 22))
        XCTAssertEqual(heights([first, second], screens, main: 982)[2], 30)
        XCTAssertEqual(heights([second, first], screens, main: 982)[2], 22)
    }

    func testAWindowBelongsToTheDisplayUnderItsCentreEvenWhenItsEdgeOverhangs() {
        let screens = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]
        // Centre x 1000: on the MacBook, though it reaches past 1512 on the right.
        let overhang = window(CGRect(x: 0, y: 0, width: 2000, height: 33))
        XCTAssertEqual(heights([overhang], screens, main: 982), [1: 33, 2: 0])
        // Centre exactly on the shared edge x = 1512: the display that starts there.
        let onEdge = window(CGRect(x: 1012, y: 0, width: 1000, height: 33))
        XCTAssertEqual(heights([onEdge], screens, main: 982), [1: 0, 2: 33])
    }

    func testTheOwnerAndTheLayerMustBothMatch() {
        let screens = [ScreenFixture.builtIn]
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 33)
        XCTAssertEqual(heights([window(bounds, owner: "window server")], screens, main: 982), [1: 0])
        XCTAssertEqual(heights([window(bounds, owner: "Window Server ")], screens, main: 982), [1: 0])
        XCTAssertEqual(heights([window(bounds, layer: 23)], screens, main: 982), [1: 0])
        XCTAssertEqual(heights([window(bounds, layer: -1)], screens, main: 982), [1: 0])
        XCTAssertEqual(heights([window(bounds)], screens, main: 982), [1: 33])
    }

    func testADecoyListedBeforeTheRealBarDoesNotShadowItOnTheSameDisplay() {
        let screens = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]
        let decoys = [
            window(CGRect(x: 1512, y: 0, width: 2560, height: 99), owner: "SystemUIServer"),
            window(CGRect(x: 1512, y: 0, width: 2560, height: 98), layer: 25),
            window(CGRect(x: 1512, y: 10, width: 2560, height: 97)),
        ]
        XCTAssertEqual(
            heights(decoys + [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal], screens, main: 982),
            [1: 33, 2: 30]
        )
    }

    func testNoDisplaysAndNoWindowsAreEmpty() {
        XCTAssertEqual(heights([MenuBarWindowFixture.builtIn], [], main: 982), [:])
        XCTAssertEqual(heights([], [], main: 0), [:])
    }

    // MARK: - The reading

    func testAReadingKeepsEachDisplaysBackingScaleAndTheReferenceNotchWidthTogether() {
        var external = ScreenFixture.secondaryExternal
        external.backingScale = 1
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, external],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        XCTAssertEqual(screens.map(\.id), [1, 2])
        XCTAssertEqual(screens.map(\.backingScale), [2, 1])
        XCTAssertEqual(screens.map(\.referenceNotchWidth), [185, 185])
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [33, 30])
        XCTAssertEqual(screens[1].frame, external.frame)
        XCTAssertEqual(screens[1].visibleFrame, external.visibleFrame)
        XCTAssertEqual(screens[0].safeAreaTop, 32)
    }

    func testAReadingWithNoNotchedDisplayHasNoReferenceWidthAndTheFallbackPill() {
        let screens = IslandScreen.attached(
            [ScreenFixture.lidClosedExternal], menuBarWindows: [MenuBarWindowFixture.lidClosedExternal]
        )
        XCTAssertEqual(screens.map(\.referenceNotchWidth), [nil])
        XCTAssertEqual(screens[0].islandNotch?.width, VirtualNotchRules.fallbackWidth)
        XCTAssertEqual(screens[0].islandNotch?.height, 30)
    }

    func testAnExternalAsMainBesideTheMacBookIsMeasuredFromTheFirstDisplay() {
        let main = ScreenFixture.lidClosedExternal // id 2, 2560 x 1440 at the origin
        let book = IslandScreen(
            id: 1, frame: CGRect(x: 2560, y: 458, width: 1512, height: 982),
            visibleFrame: CGRect(x: 2560, y: 458, width: 1512, height: 949),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        let screens = IslandScreen.attached(
            [main, book],
            menuBarWindows: [
                window(CGRect(x: 0, y: 0, width: 2560, height: 30)),
                window(CGRect(x: 2560, y: 0, width: 1512, height: 33)),
            ]
        )
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [30, 33])
        XCTAssertEqual(screens[0].islandNotch?.width, 185, "the external's pill takes the MacBook's housing width")
        XCTAssertEqual(screens[0].islandNotch?.height, 30)
        XCTAssertEqual(RestingPillRules.pills(screens).map(\.displayID), [2, 1])
    }

    func testAMeasuredZeroDropsTheVirtualNotchButNeverThePhysicalOne() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal], menuBarWindows: []
        )
        XCTAssertEqual(screens.map(\.measuredMenuBarHeight), [0, 0])
        XCTAssertNotNil(screens[0].islandNotch, "the camera housing stays")
        XCTAssertNil(screens[1].islandNotch)
        XCTAssertEqual(RestingPillRules.pills(screens).map(\.displayID), [1])
    }

    func testTheMeasuredNotchHeightOnAVirtualDisplayIsTheWindowsHeightAtTheDisplaysTop() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, window(CGRect(x: 1512, y: 0, width: 2560, height: 37))]
        )
        // Top 982, 37 pt down: 945 ..< 982, centred on 2792.
        XCTAssertEqual(screens[1].islandNotch, CGRect(x: 2699.5, y: 945, width: 185, height: 37))
    }
}
