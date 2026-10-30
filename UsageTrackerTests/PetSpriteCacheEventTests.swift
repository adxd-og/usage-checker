import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Rendering and "Owner 2026-10-30 (events)": an event's frames
/// are sprites like any other, the fur in the palette shown and the props the same in all of them;
/// nothing is built until asked, and `prewarm` builds one animal in one palette at one scale.
final class PetSpriteCacheEventTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetSpriteCacheEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func library(events: [[String: Any]] = [PetFixture.event()]) throws -> PetLibrary {
        let object = PetFixture.setting(["events"], to: events, in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        return PetLibrary.load(from: directory)
    }

    private func key(_ event: String = "hop", _ frame: String = "a", palette: String = "grey") -> PetSpriteCache.Key {
        PetSpriteCache.Key(
            animal: PetFixture.id, palette: palette,
            sprite: .eventFrame(event: event, frame: frame), pixelsPerBead: 3
        )
    }

    func testTheFurFollowsThePaletteAndThePropDoesNot() throws {
        let cache = PetSpriteCache(library: try library())
        let grey = try XCTUnwrap(cache.image(key(palette: "grey")))
        let white = try XCTUnwrap(cache.image(key(palette: "white")))
        XCTAssertEqual(grey.width, 105)
        XCTAssertEqual(PetFixture.pixel(grey, x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(white, x: 0, y: 0), [0x20, 0x20, 0x20, 255])
        XCTAssertEqual(PetFixture.pixel(grey, x: 6, y: 0), [0xff, 0, 0, 255])
        XCTAssertEqual(PetFixture.pixel(white, x: 6, y: 0), [0xff, 0, 0, 255])
    }

    func testNothingIsBuiltUntilAskedAndPrewarmBuildsOnePetInOnePalette() throws {
        let second = PetFixture.event(id: "jig")
        try PetFixture.write(
            PetFixture.setting(["id"], to: "vole", in: PetFixture.setting(["events"], to: [second], in: PetFixture.manifest())),
            folder: "vole", in: directory
        )
        let cache = PetSpriteCache(library: try library(events: [PetFixture.event(), second]))
        XCTAssertEqual(cache.count, 0)
        cache.prewarm(animal: PetFixture.id, palette: "white", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 10, "five frames, the ear, two events of two frames; no other palette or pet")
    }

    func testTwoEventsMayNameAFrameAlike() throws {
        let jig = PetFixture.setting(
            ["frames", "a"], to: PetFixture.rows(side: 35, beads: [(5, 5, "o")]), in: PetFixture.event(id: "jig")
        )
        let cache = PetSpriteCache(library: try library(events: [PetFixture.event(), jig]))
        let hopA = try XCTUnwrap(cache.image(key("hop")))
        let jigA = try XCTUnwrap(cache.image(key("jig")))
        XCTAssertEqual(PetFixture.pixel(hopA, x: 0, y: 0), [0x10, 0x10, 0x10, 255])
        XCTAssertEqual(PetFixture.pixel(jigA, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(PetFixture.pixel(jigA, x: 15, y: 15), [0x10, 0x10, 0x10, 255])
    }

    func testAnEventOrFrameThePetLacksGivesNoImageAndKeepsNothing() throws {
        let cache = PetSpriteCache(library: try library())
        XCTAssertNil(cache.image(key("nope")))
        XCTAssertNil(cache.image(key("hop", "nope")))
        XCTAssertNil(cache.image(key(palette: "pink")))
        XCTAssertEqual(cache.count, 0)
    }

    func testOnlyAnEventFrameGetsTheProps() throws {
        let manifest = try XCTUnwrap(try library().manifests[PetFixture.id])
        XCTAssertNil(manifest.colours(palette: "grey", for: .frame("idle_1"))?["x"])
        XCTAssertNil(manifest.colours(palette: "grey", for: .ear)?["x"])
        XCTAssertEqual(manifest.colours(palette: "grey", for: .eventFrame(event: "hop", frame: "a"))?["x"], PetRGB(hex: "#ff0000"))
        XCTAssertNil(manifest.colours(palette: "pink", for: .eventFrame(event: "hop", frame: "a")))
        XCTAssertEqual(PetSprite.eventFrame(event: "hop", frame: "a").description, "event hop frame a")
    }
}
