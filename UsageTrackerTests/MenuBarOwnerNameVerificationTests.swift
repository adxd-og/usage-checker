import CoreGraphics
import XCTest
@testable import Omelette

/// 4.1.0 release review OQ1 (ruling C): the menu bar window's owner is named by its process name,
/// else the window list's name; the rule accepts "WindowServer" and "Window Server", exactly.
final class MenuBarOwnerNameVerificationTests: XCTestCase {
    private func bar(_ owner: String, _ frame: CGRect, layer: Int = 24) -> MenuBarWindow {
        MenuBarWindow(ownerName: owner, layer: layer, boundsCG: frame)
    }

    private let macBookBar = CGRect(x: 0, y: 0, width: 1512, height: 33)
    private let externalBar = CGRect(x: 1512, y: 0, width: 2560, height: 30)
    private let lidOpen = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]

    private func heights(_ windows: [MenuBarWindow], on screens: [IslandScreen]? = nil, mainHeight: CGFloat = 982) -> [UInt32: CGFloat] {
        MenuBarWindowRules.heights(windows: windows, screens: screens ?? lidOpen, mainDisplayHeight: mainHeight)
    }

    // MARK: - ownerName(processName:listedName:)

    func testTheProcessNameBeatsTheListedNameWhateverTheListedNameSays() {
        for listed in ["Window Server", "Fenstertreiber", "WindowServer", "", nil] {
            XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "WindowServer", listedName: listed), "WindowServer")
        }
        // Precedence is about presence, not about which name the rule would like.
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "Dock", listedName: "Window Server"), "Dock")
    }

    func testAnEmptyOrMissingProcessNameFallsBackToTheListedName() {
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: nil, listedName: "Window Server"), "Window Server")
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "", listedName: "Fenstertreiber"), "Fenstertreiber")
    }

    func testAnEmptyOrMissingListedNameWithAProcessNameStillGivesTheProcessName() {
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "WindowServer", listedName: ""), "WindowServer")
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "WindowServer", listedName: nil), "WindowServer")
    }

    func testNeitherNameMeansNoOwner() {
        for process in [nil, ""] as [String?] {
            for listed in [nil, ""] as [String?] {
                XCTAssertNil(MenuBarWindowReader.ownerName(processName: process, listedName: listed))
            }
        }
    }

    func testTheNamesAreHandedOnAsTheyAreNotTrimmedNorFolded() {
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: "windowserver", listedName: nil), "windowserver")
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: nil, listedName: " Window Server "), " Window Server ")
        XCTAssertEqual(MenuBarWindowReader.ownerName(processName: " WindowServer ", listedName: nil), " WindowServer ")
        // So a padded process name is no menu bar owner either: the rule is exact.
        let padded = MenuBarWindowReader.ownerName(processName: " WindowServer ", listedName: "Window Server")
        XCTAssertEqual(heights([bar(padded ?? "", macBookBar)]), [1: 0, 2: 0])
    }

    // MARK: - The rule's owner set

    func testTheMeasuredSetupsGiveThirtyThreeAndThirtyWithTheProcessName() {
        let macBook = bar("WindowServer", macBookBar)
        let external = bar("WindowServer", externalBar)
        XCTAssertEqual(heights([macBook, external]), [1: 33, 2: 30], "lid open")
        XCTAssertEqual(
            heights([bar("WindowServer", CGRect(x: 0, y: 0, width: 2560, height: 30))],
                    on: [ScreenFixture.lidClosedExternal], mainHeight: 1440),
            [2: 30], "lid closed"
        )
        XCTAssertEqual(heights([macBook]), [1: 33, 2: 0], "a full-screen app on the external")
        XCTAssertEqual(heights([]), [1: 0, 2: 0], "both bars hidden")
    }

    func testEitherNameOwnsTheBarsOfOneReadingAndTheyAgreeWithTheEnglishName() {
        let mixed = [bar("WindowServer", macBookBar), bar("Window Server", externalBar)]
        XCTAssertEqual(heights(mixed), [1: 33, 2: 30])
        let english = [bar("Window Server", macBookBar), bar("Window Server", externalBar)]
        let process = [bar("WindowServer", macBookBar), bar("WindowServer", externalBar)]
        XCTAssertEqual(heights(english), heights(process))
        XCTAssertEqual(
            IslandScreen.attached(lidOpen, menuBarWindows: english), IslandScreen.attached(lidOpen, menuBarWindows: process)
        )
    }

    func testOnlyTheTwoNamesOwnTheBarEveryNearMissIsNot() {
        let nearMisses = [
            "windowserver", "WINDOWSERVER", "window server", "Window  Server", "Window\u{00A0}Server",
            "Window-Server", "WindowServer ", " Window Server", "WindowServer\n", "WindowServerX",
            "Window Servers", "WindowServ", "Window", "Server", "Window Server 2", "WindowManager",
            "Wіndow Server", "WindowServer\u{0}",
        ]
        for owner in nearMisses {
            XCTAssertEqual(heights([bar(owner, macBookBar), bar(owner, externalBar)]), [1: 0, 2: 0], owner.debugDescription)
        }
    }

    func testTheProcessNameStillNeedsTheMainMenuLayer() {
        for layer in [0, 23, 25, 101, -1] {
            XCTAssertEqual(heights([bar("WindowServer", macBookBar, layer: layer)]), [1: 0, 2: 0], "layer \(layer)")
        }
    }

    func testADecoyOfAnotherOwnerListedFirstDoesNotShadowTheWindowServersBarByItsProcessName() {
        let windows = [bar("Control Center", macBookBar), bar("WindowServer", macBookBar), bar("SystemUIServer", externalBar), bar("WindowServer", externalBar)]
        XCTAssertEqual(heights(windows), [1: 33, 2: 30])
    }
}
