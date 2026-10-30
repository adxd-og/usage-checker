import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 ("motion never leaves the habitat"), "Owner 2026-10-30 (events)"
/// and Codex's P5d plan review 3: a climb is fitted to the column's room when it starts. Rising stops
/// at the top, the pause plays there, and the descent starts from where the sprite really is, at its
/// steps' rate, ending on the floor. Steps that would only pin the sprite are not played. Worked
/// numbers: an 80-bead climb in 22 beads of room.
final class PetEventFitTests: XCTestCase {
    private let climb80 = PetEventFixture.climb80
    /// Two on the floor, up to 22, six at the top, down in the drawing's 4-bead steps, two on the floor.
    private let lifts: [Int] = [0, 0] + Array(stride(from: 2, through: 22, by: 2)) + Array(repeating: 22, count: 6)
        + [20, 16, 12, 8, 4, 0] + [0, 0]

    func testAnEventThatFitsIsPlayedAsDrawn() {
        XCTAssertEqual(climb80.fitted(room: 80), climb80)
        XCTAssertEqual(climb80.fitted(room: 120), climb80)
        XCTAssertEqual(PetEventFixture.flat.fitted(room: 0), PetEventFixture.flat)
    }

    func testAnEightyBeadClimbIn22BeadsOfRoomStopsPausesAndComesDownFromThere() {
        let fitted = climb80.fitted(room: 22)
        XCTAssertEqual(fitted.offsets.map(\.lift), lifts)
        XCTAssertEqual(fitted.steps.count, 27)
        XCTAssertEqual(fitted.duration, 2.25)
        let kept = Array(0...12) + Array(42...47) + Array(62...69)
        XCTAssertEqual(fitted.steps.map(\.frame), kept.map { $0 % 2 == 0 ? "a" : "b" }, "the drawing's own frames")
    }

    func testAtAnyRoomItPeaksThereMovesAtItsStepsRateAndEndsOnTheFloor() {
        for room in 0...80 {
            let fitted = climb80.fitted(room: room)
            let lifts = fitted.offsets.map(\.lift)
            XCTAssertEqual(lifts.max(), room, "room \(room)")
            XCTAssertEqual(fitted.offsets.last, .zero, "room \(room)")
            for (before, after) in zip(lifts, lifts.dropFirst()) {
                XCTAssertLessThanOrEqual(abs(after - before), 4, "room \(room): no jump")
            }
        }
    }

    func testWithNoRoomItPlaysInPlaceAndDoesNotCountAsMoving() {
        let fitted = climb80.fitted(room: 0)
        XCTAssertEqual(fitted.offsets.map(\.lift), Array(repeating: 0, count: 10), "floor, top pause, floor")
        XCTAssertFalse(fitted.moves)
        XCTAssertEqual(climb80.fitted(room: -3), fitted)
    }

    func testAStepThatAlsoMovesSidewaysIsKept() {
        let event = PetEventFixture.event(id: "arc", fps: 4, moves: [(0, 0), (0, -10), (3, -10), (0, 10), (-3, 10), (0, 0)])
        let fitted = event.fitted(room: 5)
        XCTAssertEqual(fitted.offsets, [
            PetEventOffset(x: 0, lift: 0), PetEventOffset(x: 0, lift: 5), PetEventOffset(x: 3, lift: 5),
            PetEventOffset(x: 0, lift: 0), PetEventOffset(x: 0, lift: 0),
        ])
    }

    func testTheRuntimeFitsAClimbWhenItStarts() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        let events = [climb80]
        _ = runtime.at(0, events: events, liftRoom: 22)
        _ = runtime.at(2, events: events, liftRoom: 22)
        for (step, lift) in lifts.enumerated() {
            let frame = runtime.at(2 + (Double(step) + 0.5) / 12, events: events, liftRoom: 22)
            XCTAssertEqual(frame.bit, .event("climb80"), "step \(step)")
            XCTAssertEqual(frame.yBeads, lift, "step \(step)")
        }
        let after = runtime.at(4.25, events: events, liftRoom: 22)
        XCTAssertNil(after.bit, "27 steps at 12 fps")
        XCTAssertEqual(after.yBeads, 0)
        XCTAssertEqual(runtime.clock.nextBitAt, 9, "the slots keep counting from its start")
    }
}
