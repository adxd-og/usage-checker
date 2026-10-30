import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime: "injected clock and random source". The pet's
/// chance is a unit draw from a source the owner injects, held inside 0 ..< 1.
final class PetRandomTests: XCTestCase {
    func testADrawStaysInsideZeroToOneWhateverTheSourceSays() {
        XCTAssertEqual(PetRandom(unit: { 0.25 }).unit(), 0.25)
        XCTAssertEqual(PetRandom(unit: { -3 }).unit(), 0)
        XCTAssertEqual(PetRandom(unit: { .nan }).unit(), 0)
        XCTAssertEqual(PetRandom(unit: { .infinity }).unit(), 0)
        XCTAssertLessThan(PetRandom(unit: { 1 }).unit(), 1)
    }

    func testValuesAndIndexesFollowTheDraw() {
        XCTAssertEqual(PetRandom(unit: { 0.25 }).value(in: 20...40), 25)
        XCTAssertEqual(PetRandom(unit: { 0 }).index(below: 3), 0)
        XCTAssertEqual(PetRandom(unit: { 0.34 }).index(below: 3), 1)
        XCTAssertEqual(PetRandom(unit: { 1 }).index(below: 3), 2)
        XCTAssertEqual(PetRandom(unit: { 0.9 }).index(below: 1), 0)
    }

    func testTheSystemSourceDrawsInsideZeroToOne() {
        let random = PetRandom.system()
        for _ in 0..<1_000 {
            let draw = random.unit()
            XCTAssertGreaterThanOrEqual(draw, 0)
            XCTAssertLessThan(draw, 1)
        }
    }

    func testTheFixtureDrawsItsValuesInOrderThenAHalf() {
        let random = PetRandomFixture.sequence([0.1, 0.9])
        XCTAssertEqual(random.unit(), 0.1)
        XCTAssertEqual(random.unit(), 0.9)
        XCTAssertEqual(random.unit(), 0.5)
        XCTAssertEqual(random.unit(), 0.5)
    }
}
