import XCTest
@testable import Omelette

/// Tester's verification of spec 2026-11-03 § Virtual notch, on displays the coder's fixtures do not
/// have: one stacked above or below the main display (non-zero y), a fractional centre, other menu
/// bar heights, a Dock at the side, a visible frame that reaches past the frame. The pill is flush
/// with the top of its own frame and centred on it; it needs the menu bar and 1280 pt of frame.
final class VirtualNotchRulesVerificationTests: XCTestCase {
    private func display(
        id: UInt32 = 20, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, menuBar: CGFloat,
        dockSide: CGFloat = 0
    ) -> IslandScreen {
        IslandScreen(
            id: id,
            frame: CGRect(x: x, y: y, width: width, height: height),
            visibleFrame: CGRect(x: x + dockSide, y: y, width: width - dockSide, height: height - menuBar),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
    }

    private func rect(_ screen: IslandScreen, reference: CGFloat? = nil) -> CGRect? {
        VirtualNotchRules.rect(screen: screen, referenceNotchWidth: reference)
    }

    func testADisplayStackedAboveTheMainOneHangsItsPillFromItsOwnTopEdge() {
        let above = display(x: 0, y: 982, width: 1920, height: 1080, menuBar: 24)
        XCTAssertEqual(rect(above), CGRect(x: 867.5, y: 2038, width: 185, height: 24))
    }

    func testADisplayBelowAndLeftOfTheMainOneWithAHalfPointCentreKeepsBothNegatives() {
        let below = display(x: -1281, y: -900, width: 1281, height: 900, menuBar: 24)
        XCTAssertEqual(rect(below), CGRect(x: -733, y: -24, width: 185, height: 24))
        XCTAssertEqual(rect(below, reference: 192), CGRect(x: -736.5, y: -24, width: 192, height: 24))
    }

    func testThePillIsFlushWithTheTopAndCentredWhateverTheWidthAndTheMenuBar() {
        for menuBar: CGFloat in [22, 24, 25, 28, 37] {
            for reference: CGFloat? in [nil, 160, 185, 192, 300] {
                let screen = display(x: -3000, y: 40, width: 2560, height: 1440, menuBar: menuBar)
                let pill = rect(screen, reference: reference)
                XCTAssertEqual(pill?.maxY, screen.frame.maxY, "menu bar \(menuBar)")
                XCTAssertEqual(pill?.midX, screen.frame.midX, "menu bar \(menuBar)")
                XCTAssertEqual(pill?.height, menuBar)
                XCTAssertEqual(pill?.width, reference ?? 185)
            }
        }
    }

    func testTheFloorIsOnTheFrameNotOnWhatADockLeavesVisible() {
        let docked = display(x: 0, y: 0, width: 1300, height: 800, menuBar: 24, dockSide: 120)
        XCTAssertEqual(docked.visibleFrame.width, 1180)
        XCTAssertEqual(rect(docked)?.midX, 650, "1300 pt of frame is enough though 1180 pt are visible")
        XCTAssertNil(rect(display(x: 0, y: 0, width: 1279.5, height: 800, menuBar: 24)))
        XCTAssertNotNil(rect(display(x: 0, y: 0, width: 1280, height: 800, menuBar: 24)))
    }

    func testAVisibleFrameThatReachesPastTheFrameIsNoMenuBar() {
        let past = IslandScreen(
            id: 21, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1100),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        XCTAssertEqual(past.menuBarHeight, 0)
        XCTAssertNil(rect(past))
        XCTAssertNil(past.islandNotch)
    }

    func testANonPositiveOrMissingReferenceWidthFallsBackTo185() {
        let screen = display(x: 0, y: 0, width: 1920, height: 1080, menuBar: 24)
        XCTAssertEqual(rect(screen, reference: -10)?.width, 185)
        XCTAssertEqual(rect(screen, reference: nil)?.width, 185)
    }

    // MARK: - IslandScreen.islandNotch / attached

    func testAPhysicalNotchIsTheIslandNotchEvenWithAHiddenMenuBarAndAnyReferenceWidth() {
        let hidden = IslandScreen(
            id: 1, frame: ScreenFixture.builtIn.frame,
            visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 904),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        XCTAssertEqual(hidden.menuBarHeight, 0)
        let physical = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        XCTAssertEqual(hidden.islandNotch, physical, "a notch needs no menu bar to be there: as in 4.0")
        var stamped = hidden
        stamped.referenceNotchWidth = 300
        XCTAssertEqual(stamped.islandNotch, physical, "a reference width never resizes the camera housing")
    }

    func testTheVirtualWidthIsTheFirstNotchedDisplaysInListOrder() {
        let read = IslandScreen.attached([ScreenFixture.externalRight, ScreenFixture.narrowNotched, ScreenFixture.builtIn])
        XCTAssertEqual(read.map(\.id), [2, 4, 1])
        XCTAssertEqual(read[0].islandNotch?.width, 192, "the first notch listed is 1352 wide's, 192")
        XCTAssertEqual(read[2].islandNotch?.width, 185, "a notch keeps its own width")
        XCTAssertEqual(read[1].islandNotch, ScreenFixture.narrowNotched.notchRect)
    }

    func testANotchedDisplayWithAHiddenMenuBarStillSetsTheReferenceWidth() {
        let hidden = IslandScreen(
            id: 4, frame: ScreenFixture.narrowNotched.frame,
            visibleFrame: CGRect(x: 0, y: 70, width: 1352, height: 808),
            safeAreaTop: 34, auxiliaryLeftWidth: 580, auxiliaryRightWidth: 580
        )
        let read = IslandScreen.attached([ScreenFixture.externalRight, hidden])
        XCTAssertEqual(read[0].islandNotch?.width, 192)
    }

    func testASafeAreaWithoutAuxiliaryAreasIsNoReferenceNotch() {
        let fake = IslandScreen(
            id: 9, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let read = IslandScreen.attached([fake, ScreenFixture.externalRight])
        XCTAssertEqual(read[1].islandNotch?.width, 185)
        XCTAssertEqual(read[0].islandNotch, CGRect(x: 663.5, y: 950, width: 185, height: 32), "virtual, as tall as its menu bar")
    }

    func testAReadingIsRestampedFromTheDisplaysNowAttachedNotFromAnEarlierOne() {
        let before = IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight])
        XCTAssertEqual(before[1].referenceNotchWidth, 185)
        let lidClosed = IslandScreen.attached([before[1]])
        XCTAssertNil(lidClosed[0].referenceNotchWidth, "no notched display attached: back to the 185 fallback")
        XCTAssertEqual(lidClosed[0].islandNotch?.width, 185)
        let other = IslandScreen.attached([before[1], ScreenFixture.narrowNotched])
        XCTAssertEqual(other[0].referenceNotchWidth, 192, "a stale 185 is replaced by the notch attached now")
    }

    func testAttachedKeepsEverythingElseAsItWas() {
        let screens = [ScreenFixture.externalLeft, ScreenFixture.builtIn, ScreenFixture.narrow1279]
        let read = IslandScreen.attached(screens)
        XCTAssertEqual(read.map(\.id), screens.map(\.id))
        XCTAssertEqual(read.map(\.frame), screens.map(\.frame))
        XCTAssertEqual(read.map(\.visibleFrame), screens.map(\.visibleFrame))
        XCTAssertEqual(read.map(\.notchRect), screens.map(\.notchRect))
        XCTAssertEqual(IslandScreen.attached([]), [])
    }
}
