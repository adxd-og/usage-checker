import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7, § 3.9, D12: with the pet off the habitat column goes at the
/// next placing; the island keeps its width and the right column takes the room. The setting comes
/// in through a closure, so no test reads the real defaults.
@MainActor
final class IslandLayoutModelPetTests: XCTestCase {
    @MainActor
    private final class Setting {
        var on = true
    }

    func testThePetOffDropsTheColumnAtTheNextPlacingAndKeepsTheWidth() {
        let setting = Setting()
        let model = IslandLayoutModel(petOn: { setting.on })
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertTrue(model.layout.showsHabitat)
        setting.on = false
        XCTAssertTrue(model.layout.showsHabitat, "nothing moves until the next open")
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertFalse(model.layout.showsHabitat)
        XCTAssertEqual(model.layout.bodyWidth, 640)
        XCTAssertEqual(model.layout.columns.right, 612)
    }

    func testThePetBackOnBringsTheColumnBack() {
        let setting = Setting()
        setting.on = false
        let model = IslandLayoutModel(petOn: { setting.on })
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertFalse(model.layout.showsHabitat)
        setting.on = true
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertTrue(model.layout.showsHabitat)
    }
}
