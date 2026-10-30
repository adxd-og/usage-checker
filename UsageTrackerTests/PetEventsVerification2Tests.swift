import XCTest
@testable import Omelette

/// Verification of P5d, the manifest and the cache (notch-island spec 2026-10-29 § 3.5, "Owner
/// 2026-10-30 (events)", § 3.8): a hostile `events` list costs only the events that are wrong and
/// never the pet; an event's props reach only its own frames; whatever is warm is warm for every
/// sprite the runtime can ask for, over the art that ships; the Debug menu's rules over it.
final class PetEventsVerification2Tests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetEventsVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - A hostile list

    private func check(events: Any?) throws -> PetManifestCheck {
        let object = PetFixture.setting(["events"], to: events, in: PetFixture.manifest())
        return PetManifestValidator.check(try PetFixture.data(object), folder: PetFixture.id)
    }

    private func hop(_ path: [String], _ value: Any?) -> [String: Any] {
        PetFixture.setting(path, to: value, in: PetFixture.event())
    }

    func testAListOfHostileEventsCostsOnlyThoseEventsAndNeverThePet() throws {
        let bigRow = String(repeating: "o", count: 36)
        let hostile: [Any] = [
            NSNull(), "hop", [1, 2], 3.5,
            hop(["id"], 7), hop(["id"], NSNull()), hop(["id"], ["a"]),
            hop(["fps"], "8"), hop(["fps"], NSNull()), hop(["fps"], true), hop(["fps"], [8]), hop(["fps"], 1e300),
            hop(["frames"], [PetFixture.frameRows]), hop(["frames"], "a"), hop(["frames"], NSNull()),
            hop(["frames", "a"], 5), hop(["frames", "a"], [bigRow]), hop(["frames", "a"], [[1]]),
            hop(["steps"], ["a": 1]), hop(["steps"], 4), hop(["steps"], [NSNull(), 3, "x", [1]]),
            hop(["steps"], [["f": "a", "dx": 1e30, "dy": 0]]),
            hop(["steps"], [["f": "a", "dx": -9_223_372_036_854_775_808, "dy": 0]]),
            hop(["steps"], [["f": "a", "dx": 9_223_372_036_854_775_807, "dy": 1]]),
            hop(["steps"], [["f": "a", "dx": 0.5, "dy": 0]]),
            hop(["steps"], [["f": "a", "dx": true, "dy": 0]]),
            hop(["steps"], [["f": "a", "dx": "1", "dy": 0]]),
            hop(["steps"], [["f": "a", "dx": NSNull(), "dy": 0]]),
            hop(["steps"], [["f": 1, "dx": 0, "dy": 0]]),
            hop(["palette"], ["x"]), hop(["palette"], "red"), hop(["palette"], ["": "#ff0000"]),
            hop(["palette"], ["xy": "#ff0000"]), hop(["palette"], ["X": "#ff0000"]), hop(["palette"], ["🙂": "#ff0000"]),
            hop(["palette"], ["x": 42]), hop(["palette"], ["x": "#12345g"]), hop(["palette"], ["x": NSNull()]),
            hop(["palette"], ["o": "#ff0000"]), hop(["palette"], ["e": "#ff0000"]),
        ]
        let result = try check(events: hostile + [PetFixture.event(id: "good")])
        XCTAssertEqual(result.issues, [], "the pet stays")
        XCTAssertEqual(result.manifest?.events.map(\.id), ["good"])
        XCTAssertEqual(result.notes.filter(\.isDroppedEvent).count, hostile.count, "each says why it went")
        // The pet is the pet it would have been with no events at all.
        let bare = try XCTUnwrap(check(events: nil).manifest)
        let kept = try XCTUnwrap(result.manifest)
        XCTAssertEqual(kept.palettes, bare.palettes)
        XCTAssertEqual(kept.frames, bare.frames)
        XCTAssertEqual(kept.animations, bare.animations)
        XCTAssertEqual(kept.still, bare.still)
        XCTAssertEqual(kept.ear, bare.ear)
    }

    func testEventsThatAreNullAnObjectOrAStringCostOnlyThemselves() throws {
        for value in [NSNull(), "hop", ["hop": 1], true] as [Any] {
            let result = try check(events: value)
            XCTAssertEqual(result.issues, [], "\(value)")
            XCTAssertNotNil(result.manifest, "\(value)")
            XCTAssertEqual(result.manifest?.events, [], "\(value)")
        }
    }

    // MARK: - Props reach only their own event

    func testTwoEventsMayColourTheSameRoleDifferentlyAndTheFurIsNeverTouched() throws {
        let red = PetFixture.event(id: "red")
        let blue = PetFixture.setting(["palette", "x"], to: "#0000ff", in: PetFixture.event(id: "blue"))
        let object = PetFixture.setting(["events"], to: [red, blue], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        let cache = PetSpriteCache(library: PetLibrary.load(from: directory))
        func image(_ sprite: PetSprite, _ palette: String = "grey") throws -> CGImage {
            try XCTUnwrap(cache.image(PetSpriteCache.Key(
                animal: PetFixture.id, palette: palette, sprite: sprite, pixelsPerBead: 1
            )))
        }
        XCTAssertEqual(PetFixture.pixel(try image(.eventFrame(event: "red", frame: "a")), x: 2, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(PetFixture.pixel(try image(.eventFrame(event: "blue", frame: "a")), x: 2, y: 0), [0, 0, 255, 255])
        // Nothing else drew that role: the pet's own frames and ear do not paint x, and keep their fur.
        XCTAssertEqual(PetFixture.pixel(try image(.frame("idle_1")), x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(try image(.frame("idle_1"), "white"), x: 0, y: 0), [0x20, 0x20, 0x20, 255])
        XCTAssertEqual(PetFixture.pixel(try image(.ear), x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(try image(.eventFrame(event: "blue", frame: "b")), x: 1, y: 0), [0x80, 0x80, 0x80, 255])
    }

    // MARK: - The art that ships

    func testWhatIsWarmIsWarmForEverySpriteTheRuntimeCanAskForAndADrawNeverBuilds() throws {
        let library = PetLibrary.bundled()
        let cache = PetSpriteCache(library: library)
        for animal in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[animal])
            for palette in manifest.paletteNames {
                XCTAssertFalse(cache.isWarm(animal: animal, palette: palette, pixelsPerBead: 1), "\(animal) \(palette) cold")
                cache.prewarm(animal: animal, palette: palette, pixelsPerBead: 1)
                XCTAssertTrue(cache.isWarm(animal: animal, palette: palette, pixelsPerBead: 1), "\(animal) \(palette)")
                XCTAssertFalse(cache.isWarm(animal: animal, palette: palette, pixelsPerBead: 2), "another scale")
            }
        }
        // Everything is built; nothing a draw asks for builds anything new.
        let built = cache.count
        for animal in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[animal])
            var sprites: [PetSprite] = manifest.frames.keys.sorted().map(PetSprite.frame) + [.ear]
            for event in manifest.events {
                sprites += event.frames.keys.sorted().map { PetSprite.eventFrame(event: event.id, frame: $0) }
            }
            for palette in manifest.paletteNames {
                for sprite in sprites {
                    let key = PetSpriteCache.Key(animal: animal, palette: palette, sprite: sprite, pixelsPerBead: 1)
                    let drawn = cache.drawableImage(key, orStill: .frame(manifest.still.idle))
                    XCTAssertNotNil(drawn, "\(animal) \(palette) \(sprite)")
                    XCTAssertTrue(drawn === cache.cachedImage(key), "\(animal) \(palette) \(sprite): the wanted one, not the still")
                }
            }
        }
        XCTAssertEqual(cache.count, built)
        // Another animal's warmth is not this one's.
        let fresh = PetSpriteCache(library: library)
        fresh.prewarm(animal: "cat", palette: "ginger", pixelsPerBead: 1)
        XCTAssertTrue(fresh.isWarm(animal: "cat", palette: "ginger", pixelsPerBead: 1))
        XCTAssertFalse(fresh.isWarm(animal: "cat", palette: "cream", pixelsPerBead: 1))
        XCTAssertFalse(fresh.isWarm(animal: "dog", palette: "tan", pixelsPerBead: 1))
    }

    func testEveryFrameTheRuntimeShowsIsAlreadyBuiltOnceThePetIsWarm() throws {
        let library = PetLibrary.bundled()
        let cache = PetSpriteCache(library: library)
        let t0 = PetRuntimeFixture.t0
        for animal in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[animal])
            let palette = manifest.paletteNames[0]
            cache.prewarm(animal: animal, palette: palette, pixelsPerBead: 1)
            let built = cache.count
            for event in manifest.events {
                for room in [0, 10, 500] {
                    var runtime = PetRuntime(random: PetRandom { 0.99 })
                    _ = runtime.tick(
                        at: t0, pose: .idle, loops: true, activity: .none, animations: manifest.animations,
                        roamBeads: 40, events: manifest.events, liftRoom: room
                    )
                    runtime.play([event.id])
                    // Up, then the mood turns to an alert half-way (a landing), then it is back.
                    for step in 0..<200 {
                        let frame = runtime.tick(
                            at: t0 + 0.05 + Double(step) / 16, pose: .look, loops: step < 24, activity: .none,
                            animations: manifest.animations, roamBeads: 40, events: manifest.events, liftRoom: room
                        )
                        let key = PetSpriteCache.Key(animal: animal, palette: palette, sprite: frame.sprite, pixelsPerBead: 1)
                        XCTAssertNotNil(cache.cachedImage(key), "\(animal) \(event.id) room \(room): \(frame.sprite) is not built")
                    }
                }
            }
            XCTAssertEqual(cache.count, built, "\(animal): playing built nothing")
        }
    }

    #if DEBUG
    func testTheDebugMenuOverTheArtThatShips() throws {
        let library = PetLibrary.bundled()
        for animal in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[animal])
            let menu = PetDebugMenuRules.menu(shown: animal, library: library, animates: true, reduceMotion: false)
            XCTAssertEqual(menu.eventIDs, manifest.events.map(\.id), animal)
            XCTAssertTrue(menu.canPlay, animal)
            XCTAssertNil(menu.note)
            XCTAssertEqual(menu.animals.filter(\.isShown).map(\.id), [animal])
            XCTAssertEqual(menu.animals.map(\.id), PetDebugMenuRules.animalOrder.filter { library.animalIDs.contains($0) })
            let palette = PetDebugMenuRules.palette(of: manifest)
            XCTAssertNotNil(manifest.palettes[palette], "\(animal): the palette the menu shows exists")
            // Every event the menu lists plays by hand.
            for id in menu.eventIDs { XCTAssertNotNil(manifest.event(id: id), "\(animal) \(id)") }
        }
        let nobody = PetDebugMenuRules.menu(shown: "nobody", library: library, animates: true, reduceMotion: false)
        XCTAssertEqual(nobody.eventIDs, [])
        XCTAssertFalse(nobody.canPlay)
        XCTAssertEqual(nobody.animals.filter(\.isShown), [])
        let reduced = PetDebugMenuRules.menu(shown: "cat", library: library, animates: false, reduceMotion: true)
        XCTAssertFalse(reduced.canPlay)
        XCTAssertNotNil(reduced.note)
        XCTAssertFalse(reduced.eventIDs.isEmpty)
    }
    #endif
}
