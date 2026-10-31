import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6: an ear's open can be about a card (the agents, keep awake).
/// The controller asks, the content takes it once and treats it as a pet click's reveal.
@MainActor
final class IslandNavigationModelCardTests: XCTestCase {
    func testNothingIsAskedAtFirst() {
        XCTAssertNil(IslandNavigationModel().requestedCard)
        XCTAssertNil(IslandNavigationModel().takeRequestedCard())
    }

    func testAnAskedCardIsTakenOnce() {
        let model = IslandNavigationModel()
        model.ask(toShow: .keepAwake)
        XCTAssertEqual(model.requestedCard, .keepAwake)
        XCTAssertEqual(model.takeRequestedCard(), .keepAwake)
        XCTAssertNil(model.requestedCard)
        XCTAssertNil(model.takeRequestedCard())
    }

    func testAskingForNothingPublishesNothing() {
        let model = IslandNavigationModel()
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        model.ask(toShow: nil)
        XCTAssertEqual(changes, 0)
        model.ask(toShow: .agents)
        model.ask(toShow: .agents)
        XCTAssertEqual(changes, 1)
        watch.cancel()
    }
}
