import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": in a looping mood about half the
/// slots play an event, never the same twice in a row. The draw order at a due slot, with no
/// stretch waiting: the coin when an event may play, then which event or which bit, then the next
/// deadline. An event plays its steps at its rate, x through the floor's clamp, y up from the floor,
/// and ends exactly where it began. Spacing counts start to start; a longer event delays the next.
/// A gate-off drops it.
///
/// Every trace: `PetRuntime.init` draws the first deadline, the first tick the open's (a draw of 0 is
/// 2 s), so the first slot is at 2 s; a next-deadline draw of 0 is 7 s.
final class PetRuntimeEventTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let flat = PetEventFixture.flat
    private let climb = PetEventFixture.climb
    private let drift = PetEventFixture.drift

    private func claude(resetsAt: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], at: t0)
    }

    // MARK: - The draws

    func testACoinBelowOneHalfPlaysTheEventTheNextDrawPicks() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.49, 0.99, 0]))
        _ = runtime.at(0)
        XCTAssertEqual(runtime.at(2).bit, .event("climb"))
        XCTAssertEqual(runtime.clock.nextBitAt, 9, "the last draw is the next deadline")
    }

    func testACoinOfOneHalfPlaysABitAsBefore() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.4, 0]))
        _ = runtime.at(0)
        XCTAssertEqual(runtime.at(2).bit, .blink, "of walk, blink, nap")
        XCTAssertEqual(runtime.clock.nextBitAt, 9)
    }

    func testEachKindOfSlotDrawsWhatItsOrderSays() {
        func drawsAtTheSlot(_ events: [PetEvent]) -> Int {
            var draws = 0
            var runtime = PetRuntime(random: PetRandom {
                draws += 1
                return 0
            })
            _ = runtime.at(0, events: events)
            let before = draws
            _ = runtime.at(2, events: events)
            return draws - before
        }
        XCTAssertEqual(drawsAtTheSlot([flat, climb]), 3, "coin, event, next deadline")
        XCTAssertEqual(drawsAtTheSlot([flat]), 2, "coin, next deadline: one event is no choice")
        XCTAssertEqual(drawsAtTheSlot([]), 2, "no coin before the art: the kind, the next deadline")
    }

    func testAWaitingStretchTakesTheSlotWithNoCoin() {
        var draws = 0
        var runtime = PetRuntime(random: PetRandom {
            draws += 1
            return 0
        })
        let reset = t0.addingTimeInterval(-3_600)
        runtime.observe([claude(resetsAt: reset)], now: reset.addingTimeInterval(-60))
        runtime.observe([claude(resetsAt: reset.addingTimeInterval(5 * 3_600))], now: t0)
        _ = runtime.at(0)
        XCTAssertEqual(draws, 2)
        XCTAssertEqual(runtime.at(2).bit, .stretch)
        XCTAssertEqual(draws, 3, "only the next deadline")
    }

    // MARK: - Never twice in a row

    func testTheSameEventNeverPlaysTwiceInARow() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0)
        XCTAssertEqual(runtime.at(2).bit, .event("flat"))
        XCTAssertEqual(runtime.lastEventID, "flat")
        XCTAssertEqual(runtime.at(9).bit, .event("climb"))
        XCTAssertEqual(runtime.at(16).bit, .event("flat"))
    }

    func testABitBetweenDoesNotMakeTheLastEventEligible() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0, 0, 0.5, 0.4, 0, 0, 0]))
        _ = runtime.at(0)
        XCTAssertEqual(runtime.at(2).bit, .event("flat"))
        XCTAssertEqual(runtime.at(9).bit, .blink, "the coin said a bit")
        XCTAssertEqual(runtime.at(16).bit, .event("climb"))
    }

    /// R1: otherwise a pet left with one event would play it once per launch.
    func testAPetWithOneEventPlaysItAgainAfterABit() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0, 0.4, 0, 0, 0]))
        _ = runtime.at(0, events: [flat])
        XCTAssertEqual(runtime.at(2, events: [flat]).bit, .event("flat"), "coin, next deadline")
        XCTAssertEqual(runtime.at(9, events: [flat]).bit, .blink, "not twice in a row, and no coin: the kind, the deadline")
        XCTAssertEqual(runtime.at(16, events: [flat]).bit, .event("flat"))
    }

    // MARK: - Playing

    func testAnEventPlaysItsStepsAtItsRateAndEndsOnTheFloor() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, events: [climb])
        for (step, lift) in [0, 2, 4, 6, 6, 6, 6, 4, 2, 0, 0, 0].enumerated() {
            let frame = runtime.at(2 + Double(step) / 8, events: [climb])
            XCTAssertEqual(frame.bit, .event("climb"), "step \(step)")
            XCTAssertEqual(frame.frame, step % 2 == 0 ? "a" : "b", "step \(step)")
            XCTAssertEqual(frame.fps, 8, "step \(step)")
            XCTAssertEqual(frame.yBeads, lift, "step \(step)")
            XCTAssertEqual(frame.xBeads, 0, "step \(step)")
        }
        let after = runtime.at(3.5, events: [climb])
        XCTAssertNil(after.bit)
        XCTAssertEqual(after.frame, "idle_1")
        XCTAssertEqual(after.fps, 2)
        XCTAssertEqual(after.yBeads, 0)
    }

    func testAnEventsSpriteIsItsOwnFrame() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        XCTAssertEqual(runtime.at(0, events: [climb]).sprite, .frame("idle_1"))
        XCTAssertEqual(runtime.at(2, events: [climb]).sprite, .eventFrame(event: "climb", frame: "a"))
        XCTAssertEqual(runtime.at(2.125, events: [climb]).sprite, .eventFrame(event: "climb", frame: "b"))
    }

    func testADriftGoesThroughTheFloorsClampAndEndsWhereItStarted() {
        var wide = PetRuntime(random: PetRandom { 0 })
        _ = wide.at(0, events: [drift])
        for (step, x) in [0, 3, 6, 3, 0, 0].enumerated() {
            XCTAssertEqual(wide.at(2 + Double(step) / 4, events: [drift]).xBeads, x, "step \(step)")
            XCTAssertEqual(wide.xBeads, 0, "the runtime's own place does not move")
        }
        XCTAssertEqual(wide.at(3.5, events: [drift]).xBeads, 0)

        var narrow = PetRuntime(random: PetRandom { 0 })
        _ = narrow.at(0, roam: 4, events: [drift])
        for (step, x) in [0, 3, 4, 3, 0, 0].enumerated() {
            XCTAssertEqual(narrow.at(2 + Double(step) / 4, roam: 4, events: [drift]).xBeads, x, "step \(step)")
        }
    }

    /// R7: a drawing's "forward" stays forward on a mirrored pet.
    func testAMirroredPetDriftsTheOtherWay() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, roam: 40, events: [])
        XCTAssertEqual(runtime.at(2, roam: 40, events: []).bit, .walk)
        _ = runtime.at(4.01, roam: 40, events: [])
        XCTAssertEqual(runtime.at(9, roam: 40, events: []).bit, .walk)
        _ = runtime.at(11.01, roam: 40, events: [])
        XCTAssertEqual(runtime.at(16, roam: 40, events: []).bit, .walk, "from 32 of 40: left")
        XCTAssertEqual(runtime.at(18.01, roam: 40, events: []).xBeads, 16)
        let start = runtime.at(23, roam: 40, events: [drift])
        XCTAssertEqual(start.bit, .event("drift"))
        XCTAssertTrue(start.facesLeft)
        XCTAssertEqual(runtime.at(23.25, roam: 40, events: [drift]).xBeads, 13)
        XCTAssertEqual(runtime.at(23.5, roam: 40, events: [drift]).xBeads, 10)
        let end = runtime.at(24.5, roam: 40, events: [drift])
        XCTAssertNil(end.bit)
        XCTAssertEqual(end.xBeads, 16)
        XCTAssertTrue(end.facesLeft)
    }

    // MARK: - Spacing

    func testSpacingCountsStartToStart() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0)
        XCTAssertEqual(runtime.at(2).bit, .event("flat"))
        XCTAssertNil(runtime.at(3.5).bit, "1.5 s long")
        XCTAssertNil(runtime.at(8.9).bit)
        XCTAssertNotNil(runtime.at(9).bit, "7 s after its start, not after its end")
    }

    func testAnEventLongerThanASlotDelaysTheNext() {
        let long = PetEventFixture.long
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0, 0, 0.5, 0.4, 0]))
        _ = runtime.at(0, events: [long, flat])
        XCTAssertEqual(runtime.at(2, events: [long, flat]).bit, .event("long"))
        XCTAssertEqual(runtime.at(9, events: [long, flat]).bit, .event("long"), "the slot due at 9 waits")
        XCTAssertEqual(runtime.clock.nextBitAt, 9)
        XCTAssertEqual(runtime.at(10, events: [long, flat]).bit, .blink, "it plays as the event ends")
        XCTAssertEqual(runtime.clock.nextBitAt, 17)
    }

    func testAnEventStartsOnlyInALoopingMoodWithTheUserAway() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0)
        XCTAssertNil(runtime.at(3, pose: .look, loops: false).bit)
        XCTAssertNil(runtime.at(4, activity: PetUserActivity(pointerOverContent: true)).bit)
        XCTAssertEqual(runtime.at(5).bit, .event("flat"))
    }

    // MARK: - The gate

    func testAGateOffDropsAClimbAndThePetIsOnTheFloorAtTheNextOpen() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, events: [climb])
        _ = runtime.at(2, events: [climb])
        XCTAssertEqual(runtime.at(2.375, events: [climb]).yBeads, 6)
        runtime.pause(at: t0 + 2.4)
        runtime.resume(at: t0 + 300)
        let frame = runtime.at(300.1, events: [climb])
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.yBeads, 0)
        XCTAssertEqual(frame.frame, "idle_1")
    }
}
