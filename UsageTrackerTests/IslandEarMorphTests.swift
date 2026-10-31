import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6: "The head morphs into the habitat pet (≈ 180 ms) only when the
/// presentation has a habitat", § 3.2 Reduce Motion: pet still. Plan rulings R7, R8.
@MainActor
final class IslandEarMorphTests: XCTestCase {
    private let retina = PetScaleRules.Scale(pixelsPerBead: 3, backingScale: 2)
    private let ear = CGRect(x: 180, y: 4, width: 24, height: 24)
    private let pet = CGRect(x: 129, y: 657.5, width: 52.5, height: 52.5)
    private var morph: IslandEarMorph { IslandEarMorph(start: 10, from: ear, to: pet) }

    func testItRunsAbout180Milliseconds() {
        XCTAssertEqual(IslandEarMorph.duration, 0.18)
        XCTAssertNotNil(morph.frame(at: 10.17))
        XCTAssertNil(morph.frame(at: 10.181))
    }

    func testItStartsOnTheEarAndEndsOnThePet() throws {
        XCTAssertEqual(try XCTUnwrap(morph.frame(at: 10)).rect, ear)
        XCTAssertEqual(try XCTUnwrap(morph.frame(at: 9)).rect, ear, "not before its start")
        let late = try XCTUnwrap(morph.frame(at: 10.179)).rect
        XCTAssertEqual(late.minX, pet.minX, accuracy: 0.1)
        XCTAssertEqual(late.minY, pet.minY, accuracy: 0.5)
        XCTAssertEqual(late.width, pet.width, accuracy: 0.1)
    }

    func testTheHeadFadesOnlyAsTheContentComesIn() throws {
        XCTAssertEqual(try XCTUnwrap(morph.frame(at: 10.11)).opacity, 1)
        XCTAssertLessThan(try XCTUnwrap(morph.frame(at: 10.17)).opacity, 0.3)
    }

    func testItMorphsOnlyFromAHeadWithAHabitatAndMotion() {
        XCTAssertTrue(IslandEarMorph.eligible(mark: .head, morphEligible: true, reduceMotion: false))
        XCTAssertFalse(IslandEarMorph.eligible(mark: .neutralDot, morphEligible: true, reduceMotion: false))
        XCTAssertFalse(IslandEarMorph.eligible(mark: nil, morphEligible: true, reduceMotion: false))
        XCTAssertFalse(IslandEarMorph.eligible(mark: .head, morphEligible: false, reduceMotion: false))
        XCTAssertFalse(IslandEarMorph.eligible(mark: .head, morphEligible: true, reduceMotion: true))
    }

    func testTheTargetIsThePetsPlaceOnTheFloor() {
        XCTAssertEqual(
            IslandEarMorph.target(
                contentOrigin: CGPoint(x: 100, y: 32), columnHeight: 700, xBeads: 10, scale: retina
            ),
            pet
        )
    }

    func testNoMeasuredColumnNoTarget() {
        XCTAssertNil(IslandEarMorph.target(contentOrigin: .zero, columnHeight: nil, xBeads: 0, scale: retina))
        XCTAssertNil(IslandEarMorph.target(contentOrigin: .zero, columnHeight: 0, xBeads: 0, scale: retina))
    }

    func testALocalRectGoesBackToGlobal() {
        let frame = CGRect(x: 629, y: 950, width: 254, height: 32)
        let global = CGRect(x: 634.5, y: 954, width: 24, height: 24)
        XCTAssertEqual(IslandGeometry.global(IslandGeometry.local(global, in: frame), in: frame), global)
    }

    func testTheModelPublishesItsFramesAndClearsAtTheEnd() {
        let model = IslandEarMorphModel()
        model.start(morph, image: nil, backingScale: 2)
        XCTAssertEqual(model.frame?.rect, ear)
        XCTAssertTrue(model.advance(to: 10.1))
        XCTAssertNotNil(model.frame)
        XCTAssertFalse(model.advance(to: 10.2))
        XCTAssertNil(model.frame)
        XCTAssertFalse(model.advance(to: 10.3), "over")
    }

    func testAStoppedModelShowsNothing() {
        let model = IslandEarMorphModel()
        model.start(morph, image: nil, backingScale: 2)
        model.stop()
        XCTAssertNil(model.frame)
        XCTAssertFalse(model.advance(to: 10.1))
    }
}
