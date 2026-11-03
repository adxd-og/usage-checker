import CoreGraphics
import XCTest
@testable import Omelette

/// Spec 2026-11-03 § Hidden menu bar and P2 plan review F6: a space change re-places the pills only
/// when the set of displays that carry an island changed, and the set follows the menu bar windows.
final class RestingPillSpaceChangeVerificationTests: XCTestCase {
    private let both = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]

    private func pills(_ screens: [IslandScreen], windows: [MenuBarWindow]) -> [RestingPillRules.Pill] {
        RestingPillRules.pills(IslandScreen.attached(screens, menuBarWindows: windows))
    }

    private let barsBoth = [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]

    func testTheNotchedMacBookAloneChangesNothingOnAnySpace() {
        // With its bar, in a full-screen space (no window), and unmeasured: the housing is always there.
        for windows in [[MenuBarWindowFixture.builtIn], []] {
            let wanted = pills([ScreenFixture.builtIn], windows: windows)
            XCTAssertEqual(wanted.map(\.displayID), [1])
            XCTAssertTrue(RestingPillRules.changes(kept: [1], wanted: wanted).isEmpty)
        }
    }

    func testAFullScreenSpaceOnTheExternalDropsOnlyItsPillAndLeavingBringsItBack() {
        let entering = RestingPillRules.changes(
            kept: [1, 2], wanted: pills(both, windows: [MenuBarWindowFixture.builtIn])
        )
        XCTAssertEqual(entering, RestingPillRules.Changes(create: [], drop: [2]))
        XCTAssertFalse(entering.isEmpty)
        let leaving = RestingPillRules.changes(kept: [1], wanted: pills(both, windows: barsBoth))
        XCTAssertEqual(leaving, RestingPillRules.Changes(create: [2], drop: []))
        XCTAssertFalse(leaving.isEmpty)
    }

    func testAnotherSpaceWithBothBarsWhereTheyWereChangesNothing() {
        XCTAssertTrue(RestingPillRules.changes(kept: [1, 2], wanted: pills(both, windows: barsBoth)).isEmpty)
    }

    func testTheMenuBarWindowsListedInAnotherOrderChangeNothing() {
        let wanted = pills(both, windows: barsBoth.reversed())
        XCTAssertTrue(RestingPillRules.changes(kept: [1, 2], wanted: wanted).isEmpty)
    }

    func testABarThatChangesHeightButStaysChangesNothing() {
        let taller = [MenuBarWindowFixture.builtIn, MenuBarWindow(
            ownerName: "Window Server", layer: 24, boundsCG: CGRect(x: 1512, y: 0, width: 2560, height: 24)
        )]
        XCTAssertTrue(RestingPillRules.changes(kept: [1, 2], wanted: pills(both, windows: taller)).isEmpty)
    }

    func testAnotherDisplayTakingTheIdOfAGoneOneIsAChange() {
        let other = IslandScreen(
            id: 9, frame: ScreenFixture.secondaryExternal.frame, visibleFrame: ScreenFixture.secondaryExternal.visibleFrame,
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let swapped = IslandScreen.attached([ScreenFixture.builtIn, other], menuBarWindows: barsBoth)
        let changes = RestingPillRules.changes(kept: [1, 2], wanted: RestingPillRules.pills(swapped))
        XCTAssertEqual(changes, RestingPillRules.Changes(create: [9], drop: [2]))
    }

    func testNothingKeptAndNothingWantedIsNoChange() {
        XCTAssertTrue(RestingPillRules.changes(kept: [], wanted: []).isEmpty)
    }

    func testDropsComeInIdOrderAndCreatesInTheDisplaysOrder() {
        let screens = [
            IslandScreen(id: 7, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1416),
                         safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil),
            IslandScreen(id: 4, frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
                         visibleFrame: CGRect(x: 2560, y: 0, width: 2560, height: 1416),
                         safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil),
        ]
        let changes = RestingPillRules.changes(kept: [30, 10, 20], wanted: RestingPillRules.pills(screens))
        XCTAssertEqual(changes, RestingPillRules.Changes(create: [7, 4], drop: [10, 20, 30]))
    }
}
