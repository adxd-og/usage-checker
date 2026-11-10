import Combine
import XCTest
@testable import Omelette

/// Small backlog spec 2026-11-10 § A (Views stop reading the window list): the views read whether a
/// display shows the island from `IslandDisplayPresence`, which the island's re-place points feed with
/// every reading they place on; an unchanged answer redraws nothing.
@MainActor
final class IslandDisplayPresenceTests: XCTestCase {
    func testAReadingWithAnIslandDisplaySetsTrue() {
        let presence = IslandDisplayPresence(screens: [ScreenFixture.externalRightMenuBarHidden])
        presence.placed(on: [ScreenFixture.externalRight, ScreenFixture.builtIn])
        XCTAssertTrue(presence.islandDisplayAttached)
    }

    func testAReadingWithoutAnIslandDisplaySetsFalse() {
        let presence = IslandDisplayPresence(screens: [ScreenFixture.builtIn])
        presence.placed(on: [ScreenFixture.externalRightMenuBarHidden, ScreenFixture.narrow1279])
        XCTAssertFalse(presence.islandDisplayAttached)
    }

    func testItStartsFromTheReadingItIsMadeWith() {
        XCTAssertTrue(IslandDisplayPresence(screens: [ScreenFixture.builtIn]).islandDisplayAttached)
        XCTAssertFalse(IslandDisplayPresence(screens: []).islandDisplayAttached)
    }

    func testTheSameAnswerTwicePublishesOnce() {
        let presence = IslandDisplayPresence(screens: [])
        var published = 0
        let observer = presence.objectWillChange.sink { published += 1 }
        presence.placed(on: [ScreenFixture.builtIn])
        presence.placed(on: [ScreenFixture.externalRight, ScreenFixture.builtIn])
        XCTAssertEqual(published, 1)
        XCTAssertTrue(presence.islandDisplayAttached)
        observer.cancel()
    }
}
