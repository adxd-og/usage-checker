import XCTest
@testable import Omelette

/// The P5d tester's finding F5, carried to P6: the habitat's "warmed for this" turned true even when
/// `prewarm` had built nothing (a palette the pet lacks), so events would play over a still. Whether
/// events may start is now the cache's word alone, and a stale choice always resolves to a palette
/// that warms.
final class PetHabitatWarmthTests: XCTestCase {
    private var directory: URL!
    private var library: PetLibrary!
    private var manifest: PetManifest!
    private var cache: PetSpriteCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetHabitatWarmthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = PetFixture.setting(["events"], to: [PetFixture.event()], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        library = PetLibrary.load(from: directory)
        manifest = try XCTUnwrap(library.manifests[PetFixture.id])
        cache = PetSpriteCache(library: library)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func playable(_ palette: String, _ pixels: Int = 3) -> [String] {
        PetHabitatRules.playableEvents(of: manifest, palette: palette, pixelsPerBead: pixels, sprites: cache).map(\.id)
    }

    func testAPaletteThePetLacksNeverPlaysEventsEvenAfterAWarmUp() {
        cache.prewarm(animal: PetFixture.id, palette: "pink", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 0, "it built nothing")
        XCTAssertEqual(playable("pink"), [])
    }

    func testEventsWaitForTheWarmUpOfThisPaletteAtThisScale() {
        XCTAssertEqual(playable("grey"), [])
        cache.prewarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(playable("grey"), ["hop"])
        XCTAssertEqual(playable("white"), [], "another palette")
        XCTAssertEqual(playable("grey", 1), [], "another scale")
    }

    func testAStaleChoiceResolvesToAPaletteThatWarms() throws {
        let shown = try XCTUnwrap(PetChoiceRules.resolved(PetChoice(animal: PetFixture.id, palette: "pink"), in: library))
        cache.prewarm(animal: shown.animal, palette: shown.palette, pixelsPerBead: 3)
        XCTAssertEqual(playable(shown.palette), ["hop"])
    }
}
