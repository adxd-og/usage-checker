import Combine
import XCTest
@testable import Omelette

/// Small backlog spec 2026-11-10 § A (Views stop reading the window list), the moments the views got
/// their answer before and must still get it: Island on displays without a notch flipped, a
/// full-screen space taking the last pill, a display removed, every display gone. The readings are
/// built as a live one is (`IslandScreen.attached(_:menuBarWindows:virtualNotchAllowed:)`), so what a
/// re-place point hands over is what the presence is checked on.
@MainActor
final class IslandDisplayPresenceVerificationTests: XCTestCase {
    private func reading(
        _ screens: [IslandScreen], menuBarWindows: [MenuBarWindow], virtualNotchAllowed: Bool = true
    ) -> [IslandScreen] {
        IslandScreen.attached(screens, menuBarWindows: menuBarWindows, virtualNotchAllowed: virtualNotchAllowed)
    }

    func testFlippingIslandOnDisplaysWithoutANotchOffAndOnMovesTheAnswerEachWay() {
        let lone = [ScreenFixture.lidClosedExternal]
        let windows = [MenuBarWindowFixture.lidClosedExternal]
        let presence = IslandDisplayPresence(screens: reading(lone, menuBarWindows: windows))
        XCTAssertTrue(presence.islandDisplayAttached)

        var published = 0
        let observer = presence.objectWillChange.sink { published += 1 }
        presence.placed(on: reading(lone, menuBarWindows: windows, virtualNotchAllowed: false))
        XCTAssertFalse(presence.islandDisplayAttached)
        presence.placed(on: reading(lone, menuBarWindows: windows, virtualNotchAllowed: true))
        XCTAssertTrue(presence.islandDisplayAttached)
        XCTAssertEqual(published, 2)
        observer.cancel()
    }

    func testAFullScreenSpaceTakingTheLastPillSetsFalseAndTheWayBackTrue() {
        let lone = [ScreenFixture.lidClosedExternal]
        let presence = IslandDisplayPresence(
            screens: reading(lone, menuBarWindows: [MenuBarWindowFixture.lidClosedExternal])
        )
        presence.placed(on: reading(lone, menuBarWindows: []))
        XCTAssertFalse(presence.islandDisplayAttached)
        presence.placed(on: reading(lone, menuBarWindows: [MenuBarWindowFixture.lidClosedExternal]))
        XCTAssertTrue(presence.islandDisplayAttached)
    }

    func testAFullScreenSpaceOnTheNotchedMacLeavesTheAnswerTrueAndPublishesNothing() {
        let notched = [ScreenFixture.builtIn]
        let presence = IslandDisplayPresence(
            screens: reading(notched, menuBarWindows: [MenuBarWindowFixture.builtIn])
        )
        var published = 0
        let observer = presence.objectWillChange.sink { published += 1 }
        presence.placed(on: reading(notched, menuBarWindows: []))
        XCTAssertTrue(presence.islandDisplayAttached)
        XCTAssertEqual(published, 0)
        observer.cancel()
    }

    func testTheLastIslandDisplayRemovedSetsFalseAndNoDisplaysAtAllStaysFalse() {
        let both = reading(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        let presence = IslandDisplayPresence(screens: both)
        XCTAssertTrue(presence.islandDisplayAttached)

        // The lid closes and the external goes to auto-hide: the one display left shows no menu bar.
        presence.placed(on: reading([ScreenFixture.lidClosedExternal], menuBarWindows: []))
        XCTAssertFalse(presence.islandDisplayAttached)

        var published = 0
        let observer = presence.objectWillChange.sink { published += 1 }
        presence.placed(on: [])
        XCTAssertFalse(presence.islandDisplayAttached)
        XCTAssertEqual(published, 0)
        observer.cancel()
    }

    func testAnIslandDisplayAmongSeveralCountsWhateverItsPlaceInTheReading() {
        // The first display of a reading shows no menu bar; the notched one comes second.
        let mixed = reading(
            [ScreenFixture.externalRightMenuBarHidden, ScreenFixture.builtIn],
            menuBarWindows: [MenuBarWindowFixture.builtIn]
        )
        XCTAssertTrue(IslandDisplayPresence(screens: mixed).islandDisplayAttached)

        let presence = IslandDisplayPresence(screens: [])
        presence.placed(on: mixed)
        XCTAssertTrue(presence.islandDisplayAttached)
    }
}
