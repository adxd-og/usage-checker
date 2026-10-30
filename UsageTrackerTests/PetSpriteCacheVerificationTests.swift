import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 Rendering ("one CGImage per animal ×
/// palette × frame, built on first use into a cache owned by the app") and plan P5a R4, R15:
/// the key separates animal, palette, frame or ear, and pixels per bead; concurrent callers see
/// one image per key; `prewarm` builds the pet on screen in one palette at one scale and
/// nothing else.
final class PetSpriteCacheVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetSpriteCacheVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ animal: String = "mouse", _ palette: String = "grey", _ sprite: PetSprite = .frame("idle_1"), _ px: Int = 3) -> PetSpriteCache.Key {
        PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: px)
    }

    /// Two animals that share a palette's name, a frame's name and a size, but not a colour.
    private func twoAnimals() throws -> PetSpriteCache {
        try PetFixture.write(PetFixture.manifest(), folder: "mouse", in: directory)
        var vole = PetFixture.setting(["id"], to: "vole", in: PetFixture.manifest())
        vole = PetFixture.setting(["palettes", "grey", "o"], to: "#aa0000", in: vole)
        try PetFixture.write(vole, folder: "vole", in: directory)
        return PetSpriteCache(library: PetLibrary.load(from: directory))
    }

    func testTwoAnimalsWithTheSameNamesNeverShareAnImage() throws {
        let cache = try twoAnimals()
        let mouse = try XCTUnwrap(cache.image(key("mouse")))
        let vole = try XCTUnwrap(cache.image(key("vole")))
        XCTAssertFalse(mouse === vole)
        XCTAssertEqual(PetFixture.pixel(mouse, x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(vole, x: 0, y: 0), [0xaa, 0x00, 0x00, 255])
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(try XCTUnwrap(cache.image(key("vole"))) === vole)
    }

    func testAFrameThatIsNamedEarIsNotTheEarHead() throws {
        var object = PetFixture.manifest()
        var frames = try XCTUnwrap(object["frames"] as? [String: Any])
        frames["ear"] = PetFixture.rows(side: 35, beads: [(0, 0, "1")])
        object["frames"] = frames
        try PetFixture.write(object, folder: "mouse", in: directory)
        let cache = PetSpriteCache(library: PetLibrary.load(from: directory))
        let frame = try XCTUnwrap(cache.image(key("mouse", "grey", .frame("ear"), 1)))
        let head = try XCTUnwrap(cache.image(key("mouse", "grey", .ear, 1)))
        XCTAssertEqual(frame.width, 35)
        XCTAssertEqual(head.width, 16)
        XCTAssertEqual(cache.count, 2)
    }

    func testEveryPixelDensityADisplayHasGetsItsOwnSizeAndItsOwnEntry() throws {
        let cache = try twoAnimals()
        for px in 1...4 {
            XCTAssertEqual(cache.image(key("mouse", "grey", .frame("idle_1"), px))?.width, 35 * px)
            XCTAssertEqual(cache.image(key("mouse", "grey", .ear, px))?.width, 16 * px)
        }
        XCTAssertEqual(cache.count, 8)
    }

    func testRequestsFromManyThreadsForSeveralImagesAllGetTheSameImagePerKey() throws {
        try PetFixture.write(PetFixture.manifest(), folder: "mouse", in: directory)
        let cache = PetSpriteCache(library: PetLibrary.load(from: directory))
        let keys = [key(), key("mouse", "white"), key("mouse", "grey", .ear), key("mouse", "grey", .frame("walk_1"), 2)]
        let seen = Collected(slots: keys.count)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let slot = i % keys.count
            if let image = cache.image(keys[slot]) { seen.add(image, slot: slot) }
        }
        XCTAssertEqual(cache.count, keys.count)
        for (slot, images) in seen.images.enumerated() {
            XCTAssertEqual(images.count, 100)
            XCTAssertTrue(images.allSatisfy { $0 === images[0] }, "key \(slot): one image, whoever built it")
            XCTAssertTrue(images[0] === cache.image(keys[slot]))
        }
    }

    func testPrewarmBuildsOnePetInOnePaletteAtOneScaleAndNothingElse() throws {
        let cache = try twoAnimals()
        cache.prewarm(animal: "mouse", palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 6)
        cache.prewarm(animal: "mouse", palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 6, "again is a lookup")
        _ = cache.image(key("mouse", "white"))
        XCTAssertEqual(cache.count, 7, "the other palette was not warmed")
        _ = cache.image(key("mouse", "grey", .frame("look"), 1))
        XCTAssertEqual(cache.count, 8, "the other scale was not warmed")
        _ = cache.image(key("vole"))
        XCTAssertEqual(cache.count, 9, "the other pet was not warmed")
    }

    func testPrewarmOfAPaletteOrScaleThatCannotBeBuiltKeepsNothing() throws {
        let cache = try twoAnimals()
        cache.prewarm(animal: "mouse", palette: "pink", pixelsPerBead: 3)
        cache.prewarm(animal: "mouse", palette: "grey", pixelsPerBead: 0)
        cache.prewarm(animal: "mouse", palette: "grey", pixelsPerBead: -2)
        cache.prewarm(animal: "nobody", palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 0)
    }

    func testPrewarmFromSeveralThreadsAtOnceBuildsEachImageOnce() throws {
        let cache = try twoAnimals()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            cache.prewarm(animal: i.isMultiple(of: 2) ? "mouse" : "vole", palette: "white", pixelsPerBead: 2)
        }
        XCTAssertEqual(cache.count, 12)
    }

    /// The doc comment's figure: 11 images, 450,216 bytes for a shipped pet's own frames and ear at
    /// 3 px per bead, and one more image per event frame, however many the art brings.
    func testAShippedPetsOwnFramesAreElevenImagesAndFourHundredFiftyThousandBytesAtThreePixels() throws {
        for animal in PetLibrary.bundled().animalIDs {
            let assets = PetAssets(library: .bundled())
            let pet = try XCTUnwrap(assets.library.manifests[animal])
            let palette = try XCTUnwrap(pet.paletteNames.first)
            let images = 11 + pet.events.reduce(0) { $0 + $1.frames.count }
            assets.sprites.prewarm(animal: animal, palette: palette, pixelsPerBead: 3)
            XCTAssertEqual(assets.sprites.count, images, animal)
            var total = 0
            for sprite in pet.frames.keys.sorted().map(PetSprite.frame) + [.ear] {
                let image = try XCTUnwrap(assets.sprites.image(PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: 3)))
                total += image.bytesPerRow * image.height
            }
            XCTAssertEqual(total, 450_216, animal)
            XCTAssertEqual(assets.sprites.count, images, "asking for the warmed images builds none: \(animal)")
        }
    }

    func testEveryShippedPetPrewarmsToItsFramesAndItsEventsInEachOfItsPalettes() throws {
        for animal in PetLibrary.bundled().animalIDs {
            let assets = PetAssets(library: .bundled())
            let pet = try XCTUnwrap(assets.library.manifests[animal])
            XCTAssertEqual(pet.frames.count, 10, animal)
            let images = 11 + pet.events.reduce(0) { $0 + $1.frames.count }
            for (n, palette) in pet.paletteNames.enumerated() {
                assets.sprites.prewarm(animal: animal, palette: palette, pixelsPerBead: 3)
                XCTAssertEqual(assets.sprites.count, images * (n + 1), "\(animal) \(palette)")
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var images: [[CGImage]]

        init(slots: Int) { images = Array(repeating: [], count: slots) }

        func add(_ image: CGImage, slot: Int) {
            lock.lock()
            images[slot].append(image)
            lock.unlock()
        }
    }
}
