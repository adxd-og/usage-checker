import XCTest
@testable import Omelette

/// Spec 2026-11-03, Amendment after the spike: a display's menu bar height is the height of the
/// window the WindowServer draws at its top at the main-menu level, 0 without one; `visibleFrame`
/// is no longer read for it. The five setups are the owner's MacBook and 2560 x 1440 external as
/// measured on 2026-11-03.
final class MenuBarWindowRulesTests: XCTestCase {
    private let lidOpen = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]

    /// The main display's AppKit height is 982 unless a test says otherwise (`builtIn` is main).
    private func heights(
        _ windows: [MenuBarWindow], on screens: [IslandScreen]? = nil, mainHeight: CGFloat = 982
    ) -> [UInt32: CGFloat] {
        MenuBarWindowRules.heights(windows: windows, screens: screens ?? lidOpen, mainDisplayHeight: mainHeight)
    }

    private func window(_ bounds: CGRect, owner: String = "Window Server", layer: Int = 24) -> MenuBarWindow {
        MenuBarWindow(ownerName: owner, layer: layer, boundsCG: bounds)
    }

    func testTheMenuBarWindowIsTheWindowServersAtTheMainMenuLevel() {
        XCTAssertEqual(MenuBarWindowRules.ownerName, "Window Server")
        XCTAssertEqual(MenuBarWindowRules.mainMenuLayer, 24)
    }

    // MARK: - The measured setups

    func testWithTheLidOpenEachDisplayTakesItsOwnMenuBarsHeight() {
        XCTAssertEqual(
            heights([MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]), [1: 33, 2: 30]
        )
    }

    func testWithTheLidClosedTheExternalAsTheMainDisplayTakesItsMenuBarsHeight() {
        XCTAssertEqual(
            heights([MenuBarWindowFixture.lidClosedExternal], on: [ScreenFixture.lidClosedExternal], mainHeight: 1440),
            [2: 30]
        )
    }

    func testAFullScreenAppOnTheExternalLeavesItNoMenuBarAndTheBuiltInItsOwn() {
        XCTAssertEqual(heights([MenuBarWindowFixture.builtIn]), [1: 33, 2: 0])
    }

    func testAHiddenMenuBarLeavesNeitherDisplayAMenuBar() {
        XCTAssertEqual(heights([]), [1: 0, 2: 0])
    }

    func testTheMenuBarSlidDownIsBackOnBothDisplays() {
        XCTAssertEqual(
            heights([MenuBarWindowFixture.secondaryExternal, MenuBarWindowFixture.builtIn]), [1: 33, 2: 30]
        )
    }

    // MARK: - What is not a menu bar

    func testAWindowOfAnotherOwnerOrLayerIsNotAMenuBar() {
        let externalTop = CGRect(x: 1512, y: 0, width: 2560, height: 24)
        let builtInTop = CGRect(x: 0, y: 0, width: 1512, height: 37)
        XCTAssertEqual(
            heights([
                window(externalTop, owner: "Control Center"),
                window(builtInTop, owner: "Brioche"),
                window(externalTop, layer: 25),
                window(builtInTop, layer: 0),
            ]),
            [1: 0, 2: 0]
        )
    }

    // MARK: - The owner's name (4.1.0 release review OQ1)

    private let macBookBar = CGRect(x: 0, y: 0, width: 1512, height: 33)

    /// The name of the WindowServer's process, which is not localized.
    func testTheWindowServerNamedByItsProcessOwnsTheMenuBar() {
        XCTAssertEqual(heights([window(macBookBar, owner: "WindowServer")]), [1: 33, 2: 0])
    }

    /// The name the window list gave on the owner's English system.
    func testTheWindowServerNamedAsTheWindowListNamesItOwnsTheMenuBar() {
        XCTAssertEqual(heights([window(macBookBar, owner: "Window Server")]), [1: 33, 2: 0])
    }

    func testAnotherOwnerAtTheMainMenuLevelIsNotAMenuBar() {
        for owner in ["WindowManager", "Control Center", "SystemUIServer", "Brioche", ""] {
            XCTAssertEqual(heights([window(macBookBar, owner: owner)]), [1: 0, 2: 0], owner)
        }
    }

    func testTheOwnersNameIsMatchedExactly() {
        for owner in ["windowserver", "WINDOWSERVER", "window server", "WINDOW SERVER", " WindowServer", "WindowServer "] {
            XCTAssertEqual(heights([window(macBookBar, owner: owner)]), [1: 0, 2: 0], owner)
        }
    }

    // MARK: - Which name the reader gives a window (4.1.0 release review OQ1)

    /// The process name wins, so a window list naming the WindowServer in another language still
    /// finds the menu bar.
    func testTheProcessNameNamesTheOwnerWhenItCanBeRead() {
        XCTAssertEqual(
            MenuBarWindowReader.ownerName(processName: "WindowServer", listedName: "Window Server"), "WindowServer"
        )
        let owner = MenuBarWindowReader.ownerName(processName: "WindowServer", listedName: "a name in another language")
        XCTAssertEqual(owner, "WindowServer")
        XCTAssertEqual(heights([window(macBookBar, owner: owner ?? "")]), [1: 33, 2: 0])
    }

    /// The WindowServer's process name could not be read, or came back empty: the window list's name.
    func testTheListedNameNamesTheOwnerWhenTheProcessNameCannotBeRead() {
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: nil, listedName: "Window Server"), "Window Server")
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "", listedName: "Window Server"), "Window Server")
    }

    func testAWindowWithNeitherNameIsSkipped() {
        XCTAssertNil(MenuBarWindowReader.ownerName(processName: nil, listedName: nil))
        XCTAssertNil(MenuBarWindowReader.ownerName(processName: "", listedName: nil))
        XCTAssertNil(MenuBarWindowReader.ownerName(processName: nil, listedName: ""))
        XCTAssertNil(MenuBarWindowReader.ownerName(processName: "", listedName: ""))
    }

    func testOtherWindowsListedFirstDoNotHideTheMenuBars() {
        let externalTop = CGRect(x: 1512, y: 0, width: 2560, height: 24)
        XCTAssertEqual(
            heights([
                window(externalTop, owner: "Control Center"),
                window(externalTop, layer: 25),
                window(CGRect(x: 0, y: 0, width: 1512, height: 982), owner: "Dock", layer: 20),
                MenuBarWindowFixture.builtIn,
                MenuBarWindowFixture.secondaryExternal,
            ]),
            [1: 33, 2: 30]
        )
    }

    func testAWindowWhoseTopIsMoreThanAPointBelowTheDisplaysTopIsNotItsMenuBar() {
        XCTAssertEqual(heights([window(CGRect(x: 1512, y: 1, width: 2560, height: 30))]), [1: 0, 2: 30], "1 pt off still counts")
        XCTAssertEqual(heights([window(CGRect(x: 1512, y: -1, width: 2560, height: 30))]), [1: 0, 2: 30])
        XCTAssertEqual(heights([window(CGRect(x: 1512, y: 2, width: 2560, height: 30))]), [1: 0, 2: 0])
        XCTAssertEqual(heights([window(CGRect(x: 1512, y: 100, width: 2560, height: 30))]), [1: 0, 2: 0])
    }

    /// The external above the built-in display: their x ranges overlap, only the top tells them apart.
    func testAMenuBarAtTheTopOfADisplayAboveIsNotTheLowerDisplays() {
        let above = IslandScreen(
            id: 6,
            frame: CGRect(x: 0, y: 982, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 982, width: 2560, height: 1440),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let screens = [ScreenFixture.builtIn, above]
        // AppKit top 2422 is CG y 982 − 2422 = −1440.
        XCTAssertEqual(heights([window(CGRect(x: 0, y: -1440, width: 2560, height: 30))], on: screens), [1: 0, 6: 30])
        XCTAssertEqual(heights([MenuBarWindowFixture.builtIn], on: screens), [1: 33, 6: 0])
    }

    /// Three displays with their tops level at 982: only the window's centre tells them apart.
    func testAMenuBarCountsOnlyForTheDisplayUnderItsCentreLeftOrRight() {
        let left = IslandScreen(
            id: 3,
            frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -98, width: 1920, height: 1080),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let screens = [ScreenFixture.builtIn, left, ScreenFixture.secondaryExternal]
        let leftBar = window(CGRect(x: -1920, y: 0, width: 1920, height: 24))
        XCTAssertEqual(heights([leftBar], on: screens), [1: 0, 3: 24, 2: 0])
        XCTAssertEqual(heights([MenuBarWindowFixture.builtIn], on: screens), [1: 33, 3: 0, 2: 0])
        XCTAssertEqual(heights([MenuBarWindowFixture.secondaryExternal], on: screens), [1: 0, 3: 0, 2: 30])
        XCTAssertEqual(
            heights([leftBar, MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal], on: screens),
            [1: 33, 3: 24, 2: 30]
        )
    }
}
