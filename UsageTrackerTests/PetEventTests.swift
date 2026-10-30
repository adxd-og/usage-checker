import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": what one event plays — the
/// whole-bead offsets its deltas add up to, up from the floor; whether it moves at all; how long
/// it lasts; the step at a moment at its own rate.
final class PetEventTests: XCTestCase {
    func testTheOffsetsAddUpTheStepsDeltas() {
        XCTAssertEqual(PetEventFixture.climb.offsets.map(\.lift), [0, 2, 4, 6, 6, 6, 6, 4, 2, 0, 0, 0])
        XCTAssertEqual(PetEventFixture.climb.offsets.map(\.x), Array(repeating: 0, count: 12))
        XCTAssertEqual(PetEventFixture.drift.offsets.map(\.x), [0, 3, 6, 3, 0, 0])
        XCTAssertEqual(PetEventFixture.drift.offsets.map(\.lift), Array(repeating: 0, count: 6))
    }

    func testOnlyAnEventWithADeltaMoves() {
        XCTAssertFalse(PetEventFixture.flat.moves)
        XCTAssertTrue(PetEventFixture.climb.moves)
        XCTAssertTrue(PetEventFixture.drift.moves)
    }

    func testADipBelowTheFloorReadsAsTheFloor() {
        let dip = PetEventFixture.event(id: "dip", fps: 4, moves: [(0, 0), (0, 2), (0, -2), (0, -3), (0, 3), (0, 0)])
        XCTAssertEqual(dip.offsets.map(\.lift), [0, 0, 0, 3, 0, 0])
    }

    func testTheDurationIsTheStepsOverTheRate() {
        XCTAssertEqual(PetEventFixture.flat.duration, 1.5)
        XCTAssertEqual(PetEventFixture.climb.duration, 1.5)
        XCTAssertEqual(PetEventFixture.long.duration, 8)
    }

    func testTheStepAtAMomentFollowsTheRateAndStaysOnTheLast() {
        let climb = PetEventFixture.climb
        XCTAssertEqual(climb.stepIndex(elapsed: -1), 0, "a clock set back")
        XCTAssertEqual(climb.stepIndex(elapsed: 0), 0)
        XCTAssertEqual(climb.stepIndex(elapsed: 0.124), 0)
        XCTAssertEqual(climb.stepIndex(elapsed: 0.125), 1)
        XCTAssertEqual(climb.stepIndex(elapsed: 1.4375), 11)
        XCTAssertEqual(climb.stepIndex(elapsed: 99), 11)
    }
}
