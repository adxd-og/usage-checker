import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering: "One CGImage per animal × palette × frame,
/// built on first use into a cache owned by the app", recoloured by palette from memory, never
/// by re-reading a file; § 3.8: once an image exists, a frame costs a lookup.
final class PetSpriteCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetSpriteCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCache() throws -> PetSpriteCache {
        try PetFixture.write(PetFixture.manifest(), folder: PetFixture.id, in: directory)
        return PetSpriteCache(library: PetLibrary.load(from: directory))
    }

    private func spriteKey(
        palette: String = "grey", sprite: PetSprite = .frame("idle_1"), pixels: Int = 3, animal: String = PetFixture.id
    ) -> PetSpriteCache.Key {
        PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: pixels)
    }

    func testAnImageIsBuiltOnFirstUseAndThenReused() throws {
        let cache = try makeCache()
        XCTAssertEqual(cache.count, 0)
        let first = try XCTUnwrap(cache.image(spriteKey()))
        XCTAssertEqual(first.width, 105)
        XCTAssertEqual(cache.count, 1)
        let again = try XCTUnwrap(cache.image(spriteKey()))
        XCTAssertTrue(first === again, "the second request is a lookup, not a new image")
        XCTAssertEqual(cache.count, 1)
    }

    func testAPaletteChangeRecoloursFromMemoryWithoutReadingTheFolderAgain() throws {
        let cache = try makeCache()
        try FileManager.default.removeItem(at: directory)
        let grey = try XCTUnwrap(cache.image(spriteKey(palette: "grey")))
        let white = try XCTUnwrap(cache.image(spriteKey(palette: "white")))
        XCTAssertEqual(PetFixture.pixel(grey, x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(white, x: 0, y: 0), [0x20, 0x20, 0x20, 255])
        XCTAssertEqual(PetFixture.pixel(white, x: 3, y: 0), [0xf0, 0xf0, 0xf0, 255])
        XCTAssertEqual(cache.count, 2)
    }

    func testEachPixelsPerBeadGetsItsOwnImage() throws {
        let cache = try makeCache()
        XCTAssertEqual(cache.image(spriteKey(pixels: 1))?.width, 35)
        XCTAssertEqual(cache.image(spriteKey(pixels: 3))?.width, 105)
        XCTAssertEqual(cache.count, 2)
    }

    func testTheEarHeadIsCachedLikeAFrame() throws {
        let cache = try makeCache()
        let ear = try XCTUnwrap(cache.image(spriteKey(sprite: .ear)))
        XCTAssertEqual(ear.width, 78)
        XCTAssertEqual(PetFixture.pixel(ear, x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(ear, x: 77, y: 77), [0x80, 0x80, 0x80, 255])
    }

    func testAPetPaletteOrFrameTheLibraryLacksGivesNoImageAndKeepsNothing() throws {
        let cache = try makeCache()
        XCTAssertNil(cache.image(spriteKey(animal: "cat")))
        XCTAssertNil(cache.image(spriteKey(palette: "pink")))
        XCTAssertNil(cache.image(spriteKey(sprite: .frame("dance"))))
        XCTAssertNil(cache.image(spriteKey(pixels: 0)))
        XCTAssertEqual(cache.count, 0)
    }

    func testPrewarmBuildsEveryFrameAndTheEarOfOnePetInOnePalette() throws {
        let cache = try makeCache()
        cache.prewarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 6, "five frames and the ear")
        cache.prewarm(animal: "cat", palette: "ginger", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 6)
    }

    func testConcurrentRequestsForOneImageKeepOne() throws {
        let cache = try makeCache()
        let wanted = spriteKey()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            _ = cache.image(wanted)
        }
        XCTAssertEqual(cache.count, 1)
    }
}
