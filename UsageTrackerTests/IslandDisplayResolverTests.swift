import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 (Display and anchor) and § 3.9 (`IslandDisplayResolver`):
/// the entry picks the display — the status item's, the notched one, the pointer's, else the
/// main one; a notch makes it the island centred on the notch, no notch a panel under the
/// status item (whatever the entry, when the item is shown on that display) clamped inside
/// the visible frame. The window reaches 8 pt above the Dock and is re-resolved on its own
/// display, or closes when that display is gone.
final class IslandDisplayResolverTests: XCTestCase {
    private let screens = [ScreenFixture.builtIn, ScreenFixture.externalRight]

    private func place(
        _ entry: IslandEntry, on screens: [IslandScreen]? = nil, main: UInt32? = 1, item: CGRect? = nil
    ) -> IslandDisplayResolver.Placement? {
        IslandDisplayResolver.placement(
            for: entry, screens: screens ?? self.screens, mainScreenID: main,
            statusItemFrame: item, panelWidth: 360, menuBarHeight: 24
        )
    }

    func testTheStatusItemOnTheNotchedDisplayOpensTheIslandOnItsNotch() {
        XCTAssertEqual(
            place(.statusItem(buttonFrame: CGRect(x: 1100, y: 950, width: 40, height: 32))),
            IslandDisplayResolver.Placement(
                kind: .island, screenID: 1,
                windowFrame: CGRect(x: 424, y: 86, width: 664, height: 896),
                anchorMidX: 756,
                notch: CGRect(x: 663.5, y: 950, width: 185, height: 32),
                bodyWidth: 640
            )
        )
    }

    func testTheStatusItemOnAnExternalDisplayOpensThePanelUnderIt() {
        XCTAssertEqual(
            place(.statusItem(buttonFrame: CGRect(x: 3800, y: 1416, width: 36, height: 24))),
            IslandDisplayResolver.Placement(
                kind: .panel, screenID: 2,
                windowFrame: CGRect(x: 3626, y: 8, width: 384, height: 1402),
                anchorMidX: 3818, notch: nil, bodyWidth: 360
            )
        )
    }

    func testAPanelNearTheRightEdgeIsClampedInsideTheVisibleFrame() {
        let panel = place(.statusItem(buttonFrame: CGRect(x: 4040, y: 1416, width: 30, height: 24)))
        XCTAssertEqual(panel?.windowFrame, CGRect(x: 3688, y: 8, width: 384, height: 1402))
        XCTAssertEqual(panel?.anchorMidX, 4055)
    }

    func testAPanelOnADisplayLeftOfTheMainOneKeepsItsNegativeOrigin() {
        let panel = place(
            .statusItem(buttonFrame: CGRect(x: -1910, y: 1056, width: 30, height: 24)),
            on: [ScreenFixture.builtIn, ScreenFixture.externalLeft]
        )
        XCTAssertEqual(panel?.screenID, 3)
        XCTAssertEqual(panel?.windowFrame, CGRect(x: -1920, y: 8, width: 384, height: 1042))
    }

    func testTheNotchAndAnEarOpenOnTheNotchedDisplayWhereverItIsListed() {
        let reversed = [ScreenFixture.externalRight, ScreenFixture.builtIn]
        XCTAssertEqual(IslandDisplayResolver.display(for: .notch, screens: reversed, mainScreenID: 2)?.id, 1)
        XCTAssertEqual(IslandDisplayResolver.display(for: .ear, screens: reversed, mainScreenID: 2)?.id, 1)
        XCTAssertEqual(place(.notch, on: reversed, main: 2)?.kind, .island)
    }

    func testWithoutANotchedDisplayTheNotchAndAnEarOpenNothing() {
        let externals = [ScreenFixture.externalRight, ScreenFixture.externalLeft]
        XCTAssertNil(place(.notch, on: externals, main: 2))
        XCTAssertNil(place(.ear, on: externals, main: 2))
    }

    func testANotificationOpensOnTheDisplayUnderThePointer() {
        XCTAssertEqual(
            place(.notification(pointer: CGPoint(x: 2000, y: 700))),
            IslandDisplayResolver.Placement(
                kind: .panel, screenID: 2,
                windowFrame: CGRect(x: 2600, y: 8, width: 384, height: 1402),
                anchorMidX: 2792, notch: nil, bodyWidth: 360
            )
        )
    }

    func testThePointerOnTheTopEdgeStillCountsForThatDisplay() {
        let island = place(.notification(pointer: CGPoint(x: 756, y: 982)), main: 2)
        XCTAssertEqual(island?.screenID, 1)
        XCTAssertEqual(island?.kind, .island)
    }

    func testAPointerOffEveryDisplayFallsBackToTheMainDisplay() {
        let lost = IslandEntry.notification(pointer: CGPoint(x: 99_999, y: 99_999))
        XCTAssertEqual(place(lost, main: 2)?.screenID, 2)
        XCTAssertEqual(place(lost, main: nil)?.screenID, 1, "no main display known: the first one")
        XCTAssertEqual(place(lost, main: 42)?.screenID, 1, "a main display that is not attached: the first one")
    }

    func testAPanelWithoutTheStatusItemOnItsDisplayHangsUnderTheMenuBarEvenWhenItHides() {
        let hiddenMenuBar = IslandScreen(
            id: 2,
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let panel = place(.notification(pointer: CGPoint(x: 2000, y: 700)), on: [ScreenFixture.builtIn, hiddenMenuBar])
        XCTAssertEqual(panel?.windowFrame.maxY, 1410, "24 pt menu bar, then the 6 pt gap")
        XCTAssertEqual(panel?.anchorMidX, 2792)
    }

    func testANotificationOnADisplayThatShowsTheStatusItemHangsUnderTheItem() {
        XCTAssertEqual(
            place(
                .notification(pointer: CGPoint(x: 2000, y: 700)),
                item: CGRect(x: 3800, y: 1416, width: 36, height: 24)
            ),
            IslandDisplayResolver.Placement(
                kind: .panel, screenID: 2,
                windowFrame: CGRect(x: 3626, y: 8, width: 384, height: 1402),
                anchorMidX: 3818, notch: nil, bodyWidth: 360
            )
        )
    }

    func testAStatusItemShownOnAnotherDisplayLeavesThePanelCentred() {
        let panel = place(
            .notification(pointer: CGPoint(x: 2000, y: 700)),
            item: CGRect(x: 1100, y: 950, width: 40, height: 32)
        )
        XCTAssertEqual(panel?.screenID, 2)
        XCTAssertEqual(panel?.anchorMidX, 2792, "the item is on the built-in display, not under the pointer")
    }

    func testANarrowNotchedDisplayGetsThe560Island() {
        XCTAssertEqual(
            place(.statusItem(buttonFrame: CGRect(x: 1000, y: 844, width: 30, height: 34)), on: [ScreenFixture.narrowNotched], main: 4),
            IslandDisplayResolver.Placement(
                kind: .island, screenID: 4,
                windowFrame: CGRect(x: 384, y: 78, width: 584, height: 800),
                anchorMidX: 676,
                notch: CGRect(x: 580, y: 844, width: 192, height: 34),
                bodyWidth: 560
            )
        )
    }

    func testAnOpenIslandIsReplacedOnItsOwnDisplay() {
        let open = place(.notch)!
        let dockHidden = IslandScreen(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        let again = IslandDisplayResolver.replacement(
            for: open, entry: .notch, screens: [ScreenFixture.externalRight, dockHidden],
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        )
        XCTAssertEqual(again?.screenID, 1)
        XCTAssertEqual(again?.windowFrame, CGRect(x: 424, y: 8, width: 664, height: 974))
    }

    func testAVanishedDisplayClosesTheIsland() {
        let open = place(.notch)!
        XCTAssertNil(IslandDisplayResolver.replacement(
            for: open, entry: .notch, screens: [ScreenFixture.externalRight],
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        ))
    }

    func testTheRestingPanelIsTheNotchRoundedOutToWholePoints() {
        XCTAssertEqual(
            IslandDisplayResolver.restingFrame(notch: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
            CGRect(x: 663, y: 950, width: 186, height: 32)
        )
    }

    func testOnlyAnEarOpensWithoutKey() {
        XCTAssertTrue(IslandEntry.statusItem(buttonFrame: .zero).becomesKey)
        XCTAssertTrue(IslandEntry.notch.becomesKey)
        XCTAssertTrue(IslandEntry.notification(pointer: .zero).becomesKey)
        XCTAssertFalse(IslandEntry.ear.becomesKey)
    }
}
