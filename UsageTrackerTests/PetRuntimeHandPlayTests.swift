import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)", the Debug trigger: an event chosen
/// by hand plays at once, whatever the mood and the slot clock, without disturbing the spacing for
/// later bits. "Play all" goes in order. A gate-off drops it all.
final class PetRuntimeHandPlayTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let pointer = PetUserActivity(pointerOverContent: true)

    func testItStartsAtTheNextTickWhateverTheMoodAndDrawsNothing() {
        var draws = 0
        var runtime = PetRuntime(random: PetRandom {
            draws += 1
            return 0
        })
        _ = runtime.at(0, pose: .sleep, loops: false)
        XCTAssertEqual(draws, 2)
        runtime.play(["climb"])
        XCTAssertEqual(runtime.at(0.5, pose: .sleep, loops: false).bit, .event("climb"), "in an open's quiet start, asleep")
        XCTAssertEqual(runtime.at(0.625, pose: .sleep, loops: false).yBeads, 2)
        XCTAssertEqual(draws, 2)
        XCTAssertEqual(runtime.clock.nextBitAt, 2, "the slot clock is as it was")
    }

    func testItIsNotCutByThePointerOrAMoodThatHoldsStill() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, pose: .look, loops: false)
        runtime.play(["flat"])
        _ = runtime.at(0.5, pose: .look, loops: false)
        XCTAssertEqual(runtime.at(0.75, pose: .look, loops: false, activity: pointer).bit, .event("flat"))
        XCTAssertEqual(runtime.at(1.9375, pose: .look, loops: false, activity: pointer).bit, .event("flat"))
        let after = runtime.at(2, pose: .look, loops: false)
        XCTAssertNil(after.bit)
        XCTAssertEqual(after.frame, "look")
    }

    func testLaterSlotsKeepTheirTimesAndItCountsAsTheLastEvent() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0)
        runtime.play(["climb"])
        _ = runtime.at(0.5)
        XCTAssertEqual(runtime.at(2).bit, .event("flat"), "the slot due at 2 s, as it ends; not climb again")
        XCTAssertEqual(runtime.clock.nextBitAt, 9)
    }

    func testPlayAllGoesInOrder() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, pose: .look, loops: false)
        runtime.play(["flat", "climb"])
        XCTAssertEqual(runtime.at(0.5, pose: .look, loops: false).bit, .event("flat"))
        XCTAssertEqual(runtime.at(1.9375, pose: .look, loops: false).bit, .event("flat"))
        XCTAssertEqual(runtime.at(2, pose: .look, loops: false).bit, .event("climb"))
        XCTAssertEqual(runtime.at(3.4375, pose: .look, loops: false).bit, .event("climb"))
        XCTAssertNil(runtime.at(3.5, pose: .look, loops: false).bit)
    }

    func testAnIdThePetDoesNotHaveIsSkipped() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, loops: false)
        runtime.play(["nope"])
        XCTAssertNil(runtime.at(0.5, loops: false).bit)
        runtime.play(["nope", "flat"])
        XCTAssertEqual(runtime.at(0.75, loops: false).bit, .event("flat"))
    }

    func testItCutsARunningBitWhereItIs() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, events: [])
        XCTAssertEqual(runtime.at(2, events: []).bit, .walk)
        XCTAssertEqual(runtime.at(2.5, events: []).xBeads, 4)
        runtime.play(["climb"])
        let frame = runtime.at(2.625)
        XCTAssertEqual(frame.bit, .event("climb"))
        XCTAssertEqual(frame.xBeads, 4)
    }

    func testAHandPlayedClimbFitsTheColumnToo() {
        let events = [PetEventFixture.climb80]
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, loops: false, events: events, liftRoom: 22)
        runtime.play(["climb80"])
        _ = runtime.at(0.5, loops: false, events: events, liftRoom: 22)
        XCTAssertEqual(runtime.at(1.75, loops: false, events: events, liftRoom: 22).yBeads, 22, "in the pause at the top")
        XCTAssertNil(runtime.at(2.75, loops: false, events: events, liftRoom: 22).bit, "27 steps at 12 fps")
    }

    func testAGateOffDropsTheQueue() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, loops: false)
        runtime.play(["flat", "climb"])
        _ = runtime.at(0.5, loops: false)
        runtime.pause(at: t0 + 1)
        runtime.resume(at: t0 + 100)
        let frame = runtime.at(100.1, loops: false)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.yBeads, 0)
    }

    func testDroppingEventsEndsTheRunningOneTheQueueAndTheMemory() {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, loops: false)
        runtime.play(["climb", "flat"])
        _ = runtime.at(0.5, loops: false)
        XCTAssertEqual(runtime.at(0.75, loops: false).yBeads, 4)
        runtime.dropEvents()
        let frame = runtime.at(0.875, loops: false)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.yBeads, 0)
        XCTAssertNil(runtime.lastEventID)
    }
}
