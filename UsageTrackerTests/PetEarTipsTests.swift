import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 Notch hint, D13: "the pet's ear tips peek out of its lower
/// edge". The tips are the head's top rows, as many whole beads as the breath's band holds (plan R9).
/// The head is built off the main thread before the first hover, on its own: § 3.5's prewarm scope
/// (all of one pet's frames and events) is for the open island.
final class PetEarTipsTests: XCTestCase {
    private let retina = PetScaleRules.Scale(pixelsPerBead: 3, backingScale: 2)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetEarTipsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func head(firstRow: Int) throws -> PetCharMap {
        try XCTUnwrap(PetCharMap(rows: PetFixture.rows(side: 16, beads: [(3, firstRow, "o")]), side: 16))
    }

    func testTheTipsStartAtTheHeadsFirstPaintedRow() throws {
        let tips = try XCTUnwrap(PetEarTips.tips(of: try head(firstRow: 2), band: 5, scale: retina))
        XCTAssertEqual(tips.crop, CGRect(x: 0, y: 6, width: 48, height: 9), "three beads at 3 px")
        XCTAssertEqual(tips.size, CGSize(width: 24, height: 4.5))
    }

    func testTheTipsStopAtTheHeadsLastRow() throws {
        let tips = try XCTUnwrap(PetEarTips.tips(of: try head(firstRow: 15), band: 5, scale: retina))
        XCTAssertEqual(tips.crop, CGRect(x: 0, y: 45, width: 48, height: 3))
    }

    func testABandTooThinForOneBeadOrAnEmptyHeadShowsNothing() throws {
        XCTAssertNil(PetEarTips.tips(of: try head(firstRow: 2), band: 1, scale: retina))
        let empty = try XCTUnwrap(PetCharMap(rows: PetFixture.rows(side: 16, beads: []), side: 16))
        XCTAssertNil(PetEarTips.tips(of: empty, band: 5, scale: retina))
    }

    func testEveryShippedHeadHasTipsInsideItsImage() throws {
        for (id, manifest) in PetLibrary.bundled().manifests {
            let tips = try XCTUnwrap(PetEarTips.tips(of: manifest.ear, band: IslandMotion.hintDown, scale: retina), id)
            XCTAssertLessThanOrEqual(tips.crop.maxY, 48, id)
            XCTAssertLessThanOrEqual(tips.size.height, IslandMotion.hintDown, id)
        }
    }

    func testTheTipsStandOnTheShapesLowerEdgeCentredOnTheNotch() {
        let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let frame = RestingLayout.frame(notch: notch, left: false, right: false, hintRoom: true)
        let layout = RestingLayout(notch: notch, left: false, right: false, appliedFrame: frame)
        let rect = layout.tipsRect(size: CGSize(width: 24, height: 4.5), look: NotchHint.Look(down: 5, widen: 3, outlined: false))
        XCTAssertEqual(rect.midX, layout.notch.midX, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, layout.notch.maxY + 5, accuracy: 0.001)
    }

    func testWarmingTheEarBuildsOnlyTheHead() throws {
        let object = PetFixture.setting(["events"], to: [PetFixture.event()], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        let cache = PetSpriteCache(library: PetLibrary.load(from: directory))
        cache.prewarmEar(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.cachedImage(PetSpriteCache.Key(animal: PetFixture.id, palette: "grey", sprite: .ear, pixelsPerBead: 3)))
        XCTAssertFalse(cache.isWarm(animal: PetFixture.id, palette: "grey", pixelsPerBead: 3), "events still wait for the pet's own warm-up")
    }

    /// Codex's plan review 5: the warm-up runs off the main thread and may land after the switch moved.
    func testAWarmUpLandingAfterThePetWasSwitchedOffShowsNothing() {
        XCTAssertFalse(PetEarTips.stillWanted(builtFor: .standard, shownNow: .standard, petOn: false))
        XCTAssertTrue(PetEarTips.stillWanted(builtFor: .standard, shownNow: .standard, petOn: true))
    }

    func testAWarmUpForAPetNoLongerShownShowsNothing() {
        let duck = PetChoice(animal: "duck", palette: "white")
        XCTAssertFalse(PetEarTips.stillWanted(builtFor: .standard, shownNow: duck, petOn: true))
        XCTAssertFalse(PetEarTips.stillWanted(builtFor: .standard, shownNow: nil, petOn: true))
    }

    func testAStalePaletteBuildsNoHead() throws {
        try PetFixture.write(PetFixture.manifest(), folder: PetFixture.id, in: directory)
        let cache = PetSpriteCache(library: PetLibrary.load(from: directory))
        cache.prewarmEar(animal: PetFixture.id, palette: "pink", pixelsPerBead: 3)
        XCTAssertEqual(cache.count, 0)
    }
}
