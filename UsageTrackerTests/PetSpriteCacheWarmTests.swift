import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.8 and Codex's P5d plan review 4: while the pet shown is being
/// warmed off the main thread, the habitat draws what is already built, the still if the wanted
/// frame is not, and never renders on the main thread on a miss; events start only once it is warm.
final class PetSpriteCacheWarmTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetSpriteCacheWarmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCache() throws -> PetSpriteCache {
        let object = PetFixture.setting(["events"], to: [PetFixture.event()], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        return PetSpriteCache(library: PetLibrary.load(from: directory))
    }

    private func key(_ sprite: PetSprite, palette: String = "grey") -> PetSpriteCache.Key {
        PetSpriteCache.Key(animal: PetFixture.id, palette: palette, sprite: sprite, pixelsPerBead: 3)
    }

    private let still = PetSprite.frame("idle_1")
    private let eventFrame = PetSprite.eventFrame(event: "hop", frame: "a")

    func testALookupNeverBuilds() throws {
        let cache = try makeCache()
        XCTAssertNil(cache.cachedImage(key(still)))
        XCTAssertEqual(cache.count, 0)
        let built = try XCTUnwrap(cache.image(key(still)))
        XCTAssertTrue(cache.cachedImage(key(still)) === built)
    }

    func testADrawTakesTheWantedFrameElseTheStillElseNothingAndNeverBuilds() throws {
        let cache = try makeCache()
        XCTAssertNil(cache.drawableImage(key(eventFrame), orStill: still), "cold: nothing to draw yet")
        XCTAssertEqual(cache.count, 0)
        let builtStill = try XCTUnwrap(cache.image(key(still)))
        XCTAssertTrue(cache.drawableImage(key(eventFrame), orStill: still) === builtStill)
        XCTAssertEqual(cache.count, 1)
        let builtFrame = try XCTUnwrap(cache.image(key(eventFrame)))
        XCTAssertTrue(cache.drawableImage(key(eventFrame), orStill: still) === builtFrame)
    }

    func testAPetIsWarmOnlyOnceItsPrewarmFinishedForThatPaletteAndScale() throws {
        let cache = try makeCache()
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3))
        _ = cache.image(key(still, palette: "white"))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3), "one image is not warm")
        cache.prewarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3)
        XCTAssertTrue(cache.isWarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 1))
    }

    func testWhatCannotBeBuiltIsNeverWarm() throws {
        let cache = try makeCache()
        cache.prewarm(animal: "nobody", palette: "grey", pixelsPerBead: 3)
        cache.prewarm(animal: PetFixture.id, palette: "pink", pixelsPerBead: 3)
        cache.prewarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 0)
        XCTAssertFalse(cache.isWarm(animal: "nobody", palette: "grey", pixelsPerBead: 3))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "pink", pixelsPerBead: 3))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 0))
    }

    func testEventsPlayOnlyOnceThePetIsWarm() {
        XCTAssertEqual(PetHabitatRules.playableEvents(PetEventFixture.both, isWarm: false), [])
        XCTAssertEqual(PetHabitatRules.playableEvents(PetEventFixture.both, isWarm: true), PetEventFixture.both)
    }
}
