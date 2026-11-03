import XCTest
@testable import Omelette

/// Verification of the island shell's placement rules against notch-island spec 2026-10-29
/// § 3.1 (Display and anchor), § 3.9, D12 and plan rulings R8/R13: arrangements the
/// executor's `IslandDisplayResolverTests` do not reach: a notched display left of the main
/// one and raised above its baseline, notches on half points, the 1419/1420/1699/1700 width
/// breakpoints as the window sees them, a status item on either edge, and a replacement that
/// follows the status item as it is now.
/// Since spec 2026-11-03 the panel's display is one without an island notch: its arrangements run on the externals with their menu bars hidden (the same numbers).
final class IslandDisplayResolverVerificationTests: XCTestCase {
    /// The 14-inch as a second, notched display to the left of the main one and raised 200 pt:
    /// every x is negative, y does not start at 0.
    private let notchedLeftRaised = IslandScreen(
        id: 7,
        frame: CGRect(x: -1512, y: 200, width: 1512, height: 982),
        visibleFrame: CGRect(x: -1512, y: 278, width: 1512, height: 872),
        safeAreaTop: 32,
        auxiliaryLeftWidth: 663.5,
        auxiliaryRightWidth: 663.5
    )

    private func place(
        _ entry: IslandEntry, on screens: [IslandScreen], main: UInt32? = nil, item: CGRect? = nil
    ) -> IslandDisplayResolver.Placement? {
        IslandDisplayResolver.placement(
            for: entry, screens: screens, mainScreenID: main,
            statusItemFrame: item, panelWidth: 360, menuBarHeight: 24
        )
    }

    private func notched(width: CGFloat) -> IslandScreen {
        IslandScreen(
            id: 9,
            frame: CGRect(x: 0, y: 0, width: width, height: 900),
            visibleFrame: CGRect(x: 0, y: 70, width: width, height: 800),
            safeAreaTop: 32,
            auxiliaryLeftWidth: (width - 185) / 2,
            auxiliaryRightWidth: (width - 185) / 2
        )
    }

    // MARK: Negative origin and a raised display

    func testTheIslandOnANotchedDisplayLeftOfTheMainOneHangsFromItsOwnTopOnItsNotch() {
        XCTAssertEqual(
            place(.notch(displayID: 7), on: [ScreenFixture.externalRight, notchedLeftRaised], main: 2),
            IslandDisplayResolver.Placement(
                kind: .island, screenID: 7,
                // 8 pt above the Dock (278 + 8), up to the display's own top edge (200 + 982).
                windowFrame: CGRect(x: -1088, y: 286, width: 664, height: 896),
                anchorMidX: -756,
                notch: CGRect(x: -848.5, y: 1150, width: 185, height: 32),
                bodyWidth: 640
            )
        )
    }

    func testTheRestingNotchOfANegativeOriginDisplayRoundsOutAwayFromTheNotch() {
        // minX -848.5 floors to -849, maxX -663.5 ceils to -663: the frame still covers the notch.
        let notch = notchedLeftRaised.notchRect!
        let frame = IslandDisplayResolver.restingFrame(notch: notch)
        XCTAssertEqual(frame, CGRect(x: -849, y: 1150, width: 186, height: 32))
        XCTAssertTrue(frame.contains(notch))
    }

    func testAWholePointNotchKeepsItsRestingFrameExact() {
        let notch = CGRect(x: 664, y: 950, width: 184, height: 32)
        XCTAssertEqual(IslandDisplayResolver.restingFrame(notch: notch), notch)
    }

    func testANotchOnQuarterPointsStillGetsAWholePointWindowThatCoversItAndAnUnroundedAnchor() {
        let quarter = IslandScreen(
            id: 5,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 872),
            safeAreaTop: 32,
            auxiliaryLeftWidth: 663.25,
            auxiliaryRightWidth: 663.5
        )
        let notch = quarter.notchRect!
        XCTAssertEqual(notch.minX, 663.25)
        XCTAssertEqual(notch.width, 185.25)
        let placement = place(.notch(displayID: 5), on: [quarter], main: 5)!
        XCTAssertEqual(placement.anchorMidX, notch.midX, "the anchor is the notch's centre, not a rounded one")
        XCTAssertEqual(placement.windowFrame.minX, placement.windowFrame.minX.rounded(), "window origins are whole points")
        XCTAssertEqual(placement.windowFrame.width, 664)
        let resting = IslandDisplayResolver.restingFrame(notch: notch)
        XCTAssertEqual(resting.minX, resting.minX.rounded())
        XCTAssertEqual(resting.maxX, resting.maxX.rounded())
        XCTAssertTrue(resting.contains(notch))
    }

    // MARK: Whole-point windows from fractional screens

    func testAnIslandWindowIsWholePointsWhenTheDockAndTheTopAreFractional() {
        let fractional = IslandScreen(
            id: 11,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982.5),
            visibleFrame: CGRect(x: 0, y: 78.4, width: 1512, height: 872.6),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        let frame = place(.notch(displayID: 11), on: [fractional], main: 11)!.windowFrame
        // Bottom: 78.4 + 8 = 86.4 rounds up so the window never reaches into the margin; top rounds down.
        XCTAssertEqual(frame.minY, 87)
        XCTAssertEqual(frame.maxY, 982)
        XCTAssertEqual(frame.minX, frame.minX.rounded())
    }

    func testAPanelWindowIsWholePointsWhenTheStatusItemSitsOnAFractionalEdge() {
        let item = CGRect(x: 3800, y: 1415.5, width: 36, height: 24)
        let frame = place(.statusItem(buttonFrame: item), on: screens)!.windowFrame
        // 1415.5 - 6 = 1409.5 rounds down: the panel never overlaps the gap under the item.
        XCTAssertEqual(frame.maxY, 1409)
        XCTAssertEqual(frame.minX, frame.minX.rounded())
    }

    // MARK: Width breakpoints as the window sees them

    func testTheWindowWidthFollowsTheBreakpointsAt1419And1420And1699And1700() {
        let widths: [(screen: CGFloat, window: CGFloat)] = [
            (1419, 560 + 24), (1420, 640 + 24), (1699, 640 + 24), (1700, 720 + 24),
        ]
        for pair in widths {
            let placement = place(.notch(displayID: 9), on: [notched(width: pair.screen)], main: 9)
            XCTAssertEqual(placement?.windowFrame.width, pair.window, "screen \(pair.screen)")
            XCTAssertEqual(
                placement?.bodyWidth, pair.window - 24, "the body is the window less the two side margins at \(pair.screen)"
            )
        }
    }

    // MARK: Which display a status-item click belongs to

    func testAStatusItemOnTheSeamBetweenTwoDisplaysBelongsToTheOneItStartsAt() {
        let seam = CGRect(x: 1512 - 15, y: 950, width: 30, height: 32)
        XCTAssertEqual(seam.midX, 1512)
        XCTAssertEqual(place(.statusItem(buttonFrame: seam), on: screens)?.screenID, 2)
        let justLeft = CGRect(x: 1512 - 31, y: 950, width: 30, height: 32)
        XCTAssertEqual(place(.statusItem(buttonFrame: justLeft), on: screens)?.screenID, 1)
    }

    func testAStatusItemOffEveryDisplayFallsBackToTheMainDisplay() {
        let lost = CGRect(x: 99_999, y: 99_999, width: 30, height: 24)
        XCTAssertEqual(place(.statusItem(buttonFrame: lost), on: screens, main: 2)?.screenID, 2)
        XCTAssertEqual(place(.statusItem(buttonFrame: lost), on: screens, main: 1)?.kind, .island)
    }

    private var screens: [IslandScreen] { [ScreenFixture.builtIn, ScreenFixture.externalRightMenuBarHidden] }

    // MARK: Clamping on both edges

    func testAPanelUnderAnItemAtTheLeftEdgeOfADisplayRightOfTheMainOneIsClampedToItsVisibleFrame() {
        // Item centred at x 1527 on the display that starts at 1512: the 384 pt window would start at 1335.
        let item = CGRect(x: 1512, y: 1416, width: 30, height: 24)
        let panel = place(.statusItem(buttonFrame: item), on: screens)
        XCTAssertEqual(panel?.screenID, 2)
        XCTAssertEqual(panel?.windowFrame.minX, 1512)
        XCTAssertEqual(panel?.anchorMidX, 1527, "the anchor stays on the item; only the window is clamped")
    }

    func testAPanelUnderAnItemAtTheRightEdgeOfADisplayLeftOfTheMainOneIsClamped() {
        let item = CGRect(x: -35, y: 1056, width: 30, height: 24)
        let panel = place(.statusItem(buttonFrame: item), on: [ScreenFixture.builtIn, ScreenFixture.externalLeftMenuBarHidden])
        XCTAssertEqual(panel?.screenID, 3)
        XCTAssertEqual(panel?.windowFrame.maxX, 0, "the visible frame ends at x 0")
        XCTAssertEqual(panel?.windowFrame, CGRect(x: -384, y: 8, width: 384, height: 1042))
    }

    func testAPanelWiderThanTheVisibleFrameStartsAtItsEdgeInsteadOfLeavingIt() {
        let tiny = IslandScreen(
            id: 8,
            frame: CGRect(x: -300, y: 0, width: 300, height: 600),
            visibleFrame: CGRect(x: -300, y: 0, width: 300, height: 576),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let panel = place(.notification(pointer: CGPoint(x: -100, y: 300)), on: [ScreenFixture.builtIn, tiny])
        XCTAssertEqual(panel?.screenID, 8)
        XCTAssertEqual(panel?.windowFrame.minX, -300)
    }

    // MARK: Re-placement follows the item as it is now (R13)

    func testAnOpenPanelFollowsTheStatusItemWhenItMovesAndFallsBackToItsClickedFrame() throws {
        let clicked = CGRect(x: 3800, y: 1416, width: 36, height: 24)
        let open = try XCTUnwrap(place(.statusItem(buttonFrame: clicked), on: screens, item: clicked))
        let moved = CGRect(x: 2000, y: 1416, width: 36, height: 24)
        let followed = IslandDisplayResolver.replacement(
            for: open, entry: .statusItem(buttonFrame: clicked), screens: screens,
            statusItemFrame: moved, panelWidth: 360, menuBarHeight: 24
        )
        XCTAssertEqual(followed?.anchorMidX, 2018, "the item's frame as it is now wins over the clicked one")
        let kept = IslandDisplayResolver.replacement(
            for: open, entry: .statusItem(buttonFrame: clicked), screens: screens,
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        )
        XCTAssertEqual(kept, open, "no shown item: the frame the click came from, unchanged")
    }

    func testAnIslandReplacedWithoutAChangeIsTheSamePlacement() throws {
        let open = try XCTUnwrap(place(.notch(displayID: 1), on: screens, main: 1))
        XCTAssertEqual(
            IslandDisplayResolver.replacement(
                for: open, entry: .notch(displayID: 1), screens: screens, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
            ),
            open
        )
    }

    func testAnIslandWhoseDisplayLostItsNotchAndItsMenuBarBecomesAPanelOnTheSameDisplay() throws {
        let open = try XCTUnwrap(place(.notch(displayID: 1), on: screens, main: 1))
        let mode = IslandScreen(
            // No menu bar either (spec 2026-11-03): no virtual notch, so the panel.
            id: 1, frame: ScreenFixture.builtIn.frame, visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 904),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let again = IslandDisplayResolver.replacement(
            for: open, entry: .notch(displayID: 1), screens: [mode, ScreenFixture.externalRight],
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        )
        XCTAssertEqual(again?.screenID, 1)
        XCTAssertEqual(again?.kind, .panel)
        XCTAssertNil(again?.notch)
    }
}
