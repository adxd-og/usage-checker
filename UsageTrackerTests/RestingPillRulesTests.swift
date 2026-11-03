import XCTest
@testable import Omelette

/// Spec 2026-11-03 § Resting pill: one resting panel per display that carries an island, physical
/// notch or virtual, keyed by display id; made for a display that gains one, dropped for one that
/// loses it or goes away.
final class RestingPillRulesTests: XCTestCase {
    private typealias Pill = RestingPillRules.Pill

    func testEveryDisplayWithAnIslandGetsOnePillOverItsNotch() {
        XCTAssertEqual(
            RestingPillRules.pills(
                IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.externalLeft])
            ),
            [
                Pill(displayID: 1, notch: CGRect(x: 663.5, y: 950, width: 185, height: 32)),
                Pill(displayID: 2, notch: CGRect(x: 2699.5, y: 1416, width: 185, height: 24)),
                Pill(displayID: 3, notch: CGRect(x: -1052.5, y: 1056, width: 185, height: 24)),
            ]
        )
    }

    func testADisplayWithoutAnIslandGetsNone() {
        XCTAssertEqual(RestingPillRules.pills([ScreenFixture.narrow1279, ScreenFixture.externalRightMenuBarHidden]), [])
        XCTAssertEqual(RestingPillRules.pills([ScreenFixture.builtIn, ScreenFixture.narrow1279]).map(\.displayID), [1])
        XCTAssertEqual(RestingPillRules.pills([]), [])
    }

    func testAPillIsAsWideAsTheAttachedNotch() {
        let pills = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.narrowNotched, ScreenFixture.externalRight]))
        XCTAssertEqual(pills.map(\.notch.width), [192, 192])
    }

    func testADisplayThatGainsAnIslandGetsAPanelAndOneThatLosesItsPanelGoes() {
        let wanted = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalLeft]))
        XCTAssertEqual(
            RestingPillRules.changes(kept: [1, 2], wanted: wanted),
            RestingPillRules.Changes(create: [3], drop: [2])
        )
    }

    func testTheSameDisplaysInAnotherOrderChangeNothing() {
        let wanted = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.externalRight, ScreenFixture.builtIn]))
        XCTAssertEqual(
            RestingPillRules.changes(kept: [1, 2], wanted: wanted),
            RestingPillRules.Changes(create: [], drop: [])
        )
    }

    func testEveryPanelGoesWhenNoDisplayCarriesAnIslandAndTheyComeBackInOrder() {
        XCTAssertEqual(
            RestingPillRules.changes(kept: [3, 1, 2], wanted: []),
            RestingPillRules.Changes(create: [], drop: [1, 2, 3])
        )
        let wanted = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.externalLeft, ScreenFixture.builtIn]))
        XCTAssertEqual(
            RestingPillRules.changes(kept: [], wanted: wanted),
            RestingPillRules.Changes(create: [3, 1], drop: [])
        )
    }

    // MARK: - A space change (spec 2026-11-03 § Hidden menu bar; review F6)

    /// The notched Mac alone, or any space that leaves every menu bar where it was: nothing to do.
    func testASpaceThatKeepsEveryIslandChangesNothing() {
        XCTAssertTrue(
            RestingPillRules.changes(kept: [1], wanted: RestingPillRules.pills([ScreenFixture.builtIn])).isEmpty
        )
        let both = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight]))
        XCTAssertTrue(RestingPillRules.changes(kept: [1, 2], wanted: both).isEmpty)
    }

    /// A full-screen space whose visible frame takes the external's menu bar away drops that pill
    /// only; leaving the space brings it back.
    func testASpaceThatHidesAnExternalsMenuBarMovesOnlyItsPill() {
        let hidden = RestingPillRules.pills(
            IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRightMenuBarHidden])
        )
        let entering = RestingPillRules.changes(kept: [1, 2], wanted: hidden)
        XCTAssertEqual(entering, RestingPillRules.Changes(create: [], drop: [2]))
        XCTAssertFalse(entering.isEmpty)
        let shown = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight]))
        XCTAssertEqual(
            RestingPillRules.changes(kept: [1], wanted: shown),
            RestingPillRules.Changes(create: [2], drop: [])
        )
    }
}
