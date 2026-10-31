import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering, § 3.7, P5d Review Focus 5: the picker shows twelve
/// stills and one idle, so that is all it builds. It marks nothing warm: a visit to Settings never
/// lets events start.
final class PetSpriteCachePickerTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()

    func testItBuildsEachCellsStillAndTheChosenPetsIdleAndNothingElse() throws {
        let cache = PetSpriteCache(library: Self.shipped)
        let cells = PetPickerRules.columns(library: Self.shipped, selected: .standard).flatMap(\.cells).map(\.choice)
        cache.prewarmPicker(cells: cells, selected: .standard, pixelsPerBead: 1)
        XCTAssertEqual(cache.count, 13, "twelve idle_1 stills and the cat's idle_2")
        XCTAssertNotNil(cache.cachedImage(PetSpriteCache.Key(animal: "cat", palette: "ginger", sprite: .frame("idle_2"), pixelsPerBead: 1)))
        XCTAssertNil(cache.cachedImage(PetSpriteCache.Key(animal: "dog", palette: "tan", sprite: .frame("idle_2"), pixelsPerBead: 1)))
    }

    func testItMarksNothingWarm() {
        let cache = PetSpriteCache(library: Self.shipped)
        cache.prewarmPicker(cells: [.standard], selected: .standard, pixelsPerBead: 1)
        XCTAssertFalse(cache.isWarm(animal: "cat", palette: "ginger", pixelsPerBead: 1))
    }

    func testAPetTheLibraryLacksBuildsNothing() {
        let cache = PetSpriteCache(library: Self.shipped)
        let otter = PetChoice(animal: "otter", palette: "brown")
        cache.prewarmPicker(cells: [otter], selected: otter, pixelsPerBead: 1)
        XCTAssertEqual(cache.count, 0)
    }
}
