import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": an event that moves is not cut by
/// the pointer or a focused field, since a climbing pet snapped to the floor looks broken; one that
/// stays in its frame stops like any bit (§ 3.5 Runtime). A mood that stops looping brings a moved
/// pet back in 0.4 s (OWNER 1). A pat lets it play on (OWNER 3). All on a constant draw of 0: the
/// slot at 2 s plays the one event given.
final class PetRuntimeEventInterruptionTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let climb = [PetEventFixture.climb]
    private let drift = [PetEventFixture.drift]
    private let flat = [PetEventFixture.flat]
    private let pointer = PetUserActivity(pointerOverContent: true)
    private let field = PetUserActivity(fieldFocused: true)

    private func runtimePlaying(_ events: [PetEvent]) -> PetRuntime {
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, events: events)
        _ = runtime.at(2, events: events)
        return runtime
    }

    func testAnEventThatMovesFinishesUnderThePointerAndAField() {
        var runtime = runtimePlaying(climb)
        XCTAssertEqual(runtime.at(2.25, activity: pointer, events: climb).yBeads, 4)
        let frame = runtime.at(2.375, activity: field, events: climb)
        XCTAssertEqual(frame.bit, .event("climb"))
        XCTAssertEqual(frame.yBeads, 6)
        XCTAssertEqual(runtime.at(3.4375, activity: pointer, events: climb).bit, .event("climb"))
        let after = runtime.at(3.5, activity: pointer, events: climb)
        XCTAssertNil(after.bit)
        XCTAssertEqual(after.yBeads, 0)
    }

    func testASidewaysEventFinishesToo() {
        var runtime = runtimePlaying(drift)
        let frame = runtime.at(2.5, activity: pointer, events: drift)
        XCTAssertEqual(frame.bit, .event("drift"))
        XCTAssertEqual(frame.xBeads, 6)
    }

    func testAnEventThatStaysInItsFrameStopsLikeAnyBit() {
        var runtime = runtimePlaying(flat)
        let frame = runtime.at(2.25, activity: pointer, events: flat)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.frame, "idle_1")
    }

    func testAMoodThatStopsLoopingBringsAClimbingPetDownFast() {
        var runtime = runtimePlaying(climb)
        var frame = runtime.at(2.5, pose: .look, loops: false, events: climb)
        XCTAssertEqual(frame.bit, .event("climb"), "it starts down from where it is")
        XCTAssertEqual(frame.frame, "a", "on the frame it was on")
        XCTAssertEqual(frame.yBeads, 6)
        XCTAssertEqual(frame.fps, PetRuntime.landingFPS)
        frame = runtime.at(2.7, pose: .look, loops: false, events: climb)
        XCTAssertEqual(frame.yBeads, 3, "half way at half the 0.4 s")
        XCTAssertEqual(frame.frame, "a")
        frame = runtime.at(2.95, pose: .look, loops: false, events: climb)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.frame, "look")
        XCTAssertEqual(frame.yBeads, 0)
        XCTAssertEqual(frame.fps, 1)
    }

    func testASidewaysEventComesBackTheSameWay() {
        var runtime = runtimePlaying(drift)
        XCTAssertEqual(runtime.at(2.5, pose: .look, loops: false, events: drift).xBeads, 6)
        XCTAssertEqual(runtime.at(2.7, pose: .look, loops: false, events: drift).xBeads, 3)
        XCTAssertEqual(runtime.at(2.95, pose: .look, loops: false, events: drift).xBeads, 0)
    }

    /// Codex plan review 3: the descent starts where the sprite is, not at the drawing's 80 beads.
    func testADescentInAShortColumnStartsWhereTheSpriteReallyIs() {
        let events = [PetEventFixture.climb80]
        var runtime = PetRuntime(random: PetRandom { 0 })
        _ = runtime.at(0, events: events, liftRoom: 22)
        _ = runtime.at(2, events: events, liftRoom: 22)
        XCTAssertEqual(runtime.at(3.25, events: events, liftRoom: 22).yBeads, 22, "in the pause at the top")
        XCTAssertEqual(runtime.at(3.25, pose: .look, loops: false, events: events, liftRoom: 22).yBeads, 22)
        XCTAssertEqual(runtime.at(3.45, pose: .look, loops: false, events: events, liftRoom: 22).yBeads, 11)
        let after = runtime.at(3.7, pose: .look, loops: false, events: events, liftRoom: 22)
        XCTAssertNil(after.bit)
        XCTAssertEqual(after.yBeads, 0)
    }

    func testAnEventAtItsStartingSpotJustEnds() {
        var climbing = runtimePlaying(climb)
        XCTAssertNil(climbing.at(2.0625, pose: .look, loops: false, events: climb).bit, "step 0, nothing to come down from")
        var still = runtimePlaying(flat)
        XCTAssertNil(still.at(2.25, pose: .look, loops: false, events: flat).bit)
    }

    func testAMoodThatLoopsAgainDoesNotPutThePetBackUp() {
        var runtime = runtimePlaying(climb)
        _ = runtime.at(2.5, pose: .look, loops: false, events: climb)
        let frame = runtime.at(2.7, events: climb)
        XCTAssertEqual(frame.yBeads, 3, "it keeps coming down")
        XCTAssertEqual(frame.fps, PetRuntime.landingFPS)
        XCTAssertNil(runtime.at(2.95, events: climb).bit)
    }

    func testClosingDuringTheDescentLeavesThePetOnTheFloor() {
        var runtime = runtimePlaying(climb)
        XCTAssertEqual(runtime.at(2.5, pose: .look, loops: false, events: climb).yBeads, 6)
        runtime.pause(at: t0 + 2.6)
        runtime.resume(at: t0 + 300)
        let frame = runtime.at(300.1, events: climb)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.yBeads, 0)
    }

    func testAPatLetsAnEventPlayOnWithItsHeart() {
        var runtime = runtimePlaying(climb)
        runtime.pat(at: t0 + 2.25)
        let frame = runtime.at(2.375, events: climb)
        XCTAssertEqual(frame.bit, .event("climb"))
        XCTAssertEqual(frame.yBeads, 6)
        XCTAssertTrue(frame.showsHeart)
        XCTAssertEqual(runtime.clock.nextBitAt, 9.25, "the next slot is put off as for any pat")
    }
}
