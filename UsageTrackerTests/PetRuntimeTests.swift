import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime and § 3.9 `PetRuntime`: each pose plays its own
/// animation; while the mood loops (Idle, and Agent working by the owner's ruling of
/// 2026-10-30) the idle loop plays a bit (walk, blink, nap; sitting is the idle pose) at most
/// every 7–10 s of visible open time, each open's first 2–4 s into it (owner 2026-10-30, first
/// look at the pet), never in an open's first 1.5 s, never while the pointer is over the right
/// column or a field has focus; motion never leaves the habitat and moves in whole beads; a
/// pause ends a bit; a still pet shows its current mood's still.
final class PetRuntimeTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let stills = PetRuntimeFixture.stills

    private func tick(
        _ runtime: inout PetRuntime,
        _ seconds: TimeInterval,
        pose: PetPose = .idle,
        loops: Bool = true,
        activity: PetUserActivity = .none,
        roam: Int = PetRuntimeFixture.roam
    ) -> PetFrame {
        runtime.tick(
            at: t0 + seconds, pose: pose, loops: loops, activity: activity,
            animations: PetRuntimeFixture.animations, roamBeads: roam
        )
    }

    func testTheFixtureIsTheShippedCat() throws {
        let cat = try XCTUnwrap(PetLibrary.bundled().manifests["cat"])
        XCTAssertEqual(cat.animations, PetRuntimeFixture.animations)
        XCTAssertEqual(cat.still, stills)
    }

    func testEveryFrameTheRuntimeCanPickExistsInEveryShippedPet() {
        let library = PetLibrary.bundled()
        XCTAssertEqual(library.animalIDs, ["cat", "dog", "duck", "raccoon"])
        let names = PetPose.allCases.map(\.animation) + [PetBit.walk, .blink, .nap].map(\.animation)
        for (id, manifest) in library.manifests {
            for name in names {
                for frame in manifest.animations[name].frames {
                    XCTAssertNotNil(manifest.frames[frame], "\(id) \(name) \(frame)")
                }
            }
            for pose in PetPose.allCases {
                XCTAssertNotNil(manifest.frames[manifest.still[pose]], "\(id) still \(pose)")
            }
        }
    }

    func testEachPoseShowsItsOwnAnimationFromItsFirstFrame() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.99]))
        var frame = tick(&runtime, 0, loops: false)
        XCTAssertEqual(frame.frame, "idle_1")
        XCTAssertEqual(frame.fps, 2)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(tick(&runtime, 0.75, loops: false).frame, "idle_2")
        XCTAssertEqual(tick(&runtime, 1.25, loops: false).frame, "idle_1")
        frame = tick(&runtime, 2, pose: .sleep, loops: false)
        XCTAssertEqual(frame.frame, "sleep_1")
        XCTAssertEqual(frame.fps, 1.5)
        XCTAssertEqual(tick(&runtime, 2.9, pose: .sleep, loops: false).frame, "sleep_2")
        frame = tick(&runtime, 3.5, pose: .look, loops: false)
        XCTAssertEqual(frame.frame, "look")
        XCTAssertEqual(frame.fps, 1)
    }

    func testAfterAPauseThePoseStartsAgainFromItsFirstFrame() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.99]))
        _ = tick(&runtime, 0, loops: false)
        XCTAssertEqual(tick(&runtime, 0.75, loops: false).frame, "idle_2")
        runtime.pause(at: t0 + 1)
        runtime.resume(at: t0 + 10)
        XCTAssertEqual(tick(&runtime, 10.1, loops: false).frame, "idle_1")
    }

    /// Reduce Motion, or the entrance: the current mood's still, never a pose an earlier mood or a
    /// nap left behind (the rule reads no history).
    func testAStillPetShowsItsCurrentMoodsStill() {
        XCTAssertEqual(PetRuntime.still(pose: .idle, stills: stills), "idle_1", "idle or agents working")
        XCTAssertEqual(PetRuntime.still(pose: .look, stills: stills), "look", "an alert")
        XCTAssertEqual(PetRuntime.still(pose: .sleep, stills: stills), "sleep_1", "keep awake at night, nothing on")
    }

    func testTheFirstBitWaitsForItsDeadline() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5, 0.5]))
        XCTAssertNil(tick(&runtime, 0).bit)
        XCTAssertNil(tick(&runtime, 2.9).bit)
        XCTAssertEqual(tick(&runtime, 3).bit, .blink)
    }

    /// The owner opens the island for a few seconds, never for 40: whatever the draws, a bit shows.
    func testAShortOpenStillShowsABit() {
        for draw in [0, 0.5, 0.99, 1] {
            var runtime = PetRuntime(random: PetRandomFixture.sequence([draw, draw, 0, 0.5]))
            var bits: [PetBit] = []
            for step in 0..<79 {
                if let bit = tick(&runtime, Double(step) / 16).bit { bits.append(bit) }
            }
            XCTAssertFalse(bits.isEmpty, "draw \(draw): 4.875 s open, no bit")
        }
    }

    func testAnOpenAfterALongClosedTimePlaysItsFirstBit2To4SecondsIn() {
        for (draw, due) in [(0.0, 2.0), (0.5, 3.0), (0.75, 3.5)] {
            var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.5, draw, 0.5, 0.5]))
            _ = tick(&runtime, 0)
            XCTAssertEqual(tick(&runtime, 2).bit, .blink, "the first open's bit, 8.5 s to the next")
            runtime.pause(at: t0 + 2.5)
            runtime.resume(at: t0 + 10_000)
            XCTAssertNil(tick(&runtime, 10_000 + due - 0.1).bit, "draw \(draw)")
            XCTAssertEqual(tick(&runtime, 10_000 + due).bit, .blink, "draw \(draw)")
        }
    }

    func testAResumeWhileRunningAndATickThatStartsNothingDrawNothing() {
        var draws = 0
        var runtime = PetRuntime(random: PetRandom {
            draws += 1
            return 0.5
        })
        XCTAssertEqual(draws, 1, "the clock's first deadline")
        runtime.resume(at: t0)
        XCTAssertEqual(draws, 2, "this open's first bit: 3 s in")
        runtime.resume(at: t0 + 0.5)
        _ = tick(&runtime, 1)
        _ = tick(&runtime, 2.9)
        XCTAssertEqual(draws, 2)
        XCTAssertEqual(tick(&runtime, 3).bit, .blink)
        XCTAssertEqual(draws, 4, "the bit's kind and the next deadline")
        _ = tick(&runtime, 3.1)
        XCTAssertEqual(draws, 4)
    }

    /// `tick` resumes a paused clock (a runtime no keeper guards): that is an open like any other.
    func testATickOnAPausedClockStartsAnOpenWithItsOwnDraw() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.5, 0.75]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 2).bit, .blink)
        runtime.pause(at: t0 + 2.5)
        XCTAssertNil(tick(&runtime, 100).bit, "this tick opened it")
        XCTAssertEqual(runtime.clock.nextBitAt, 2.5 + 3.5, accuracy: 1e-9)
    }

    func testNoBitInTheFirstSecondAndAHalfOfAnOpen() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0.5]))
        runtime.resume(at: t0)
        runtime.pause(at: t0 + 30)
        runtime.resume(at: t0 + 100)
        XCTAssertNil(tick(&runtime, 100).bit)
        XCTAssertNil(tick(&runtime, 101.4).bit, "30 s seen, past the deadline, but the open is 1.4 s old")
        XCTAssertEqual(tick(&runtime, 101.5).bit, .blink)
    }

    func testBitsPlayOnlyWhileTheMoodLoops() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5, 0.5]))
        XCTAssertNil(tick(&runtime, 0, pose: .look, loops: false).bit)
        XCTAssertNil(tick(&runtime, 5, pose: .look, loops: false).bit, "an alert: the pet holds still")
        XCTAssertNil(tick(&runtime, 6, pose: .sleep, loops: false).bit, "keep awake at night: it sleeps")
        XCTAssertEqual(tick(&runtime, 7).bit, .blink, "calm again (idle or agents working), the bit due since 3 s plays")
    }

    func testABitWaitsWhileThePointerIsOverTheContentOrAFieldHasFocus() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertNil(tick(&runtime, 3, activity: PetUserActivity(pointerOverContent: true)).bit)
        XCTAssertNil(tick(&runtime, 4, activity: PetUserActivity(fieldFocused: true)).bit)
        XCTAssertEqual(tick(&runtime, 5).bit, .blink)
    }

    func testARunningBitStopsWhenTheUserTurnsToTheContent() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 3).bit, .walk)
        let frame = tick(&runtime, 3.25, activity: PetUserActivity(pointerOverContent: true))
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.frame, "idle_1")
    }

    func testAWalkMovesABeadAFrameTowardTheFartherEdge() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0, 0, 0]))
        _ = tick(&runtime, 0)
        var frame = tick(&runtime, 2)
        XCTAssertEqual(frame.bit, .walk)
        XCTAssertEqual(frame.frame, "walk_1")
        XCTAssertEqual(frame.fps, 8)
        XCTAssertEqual(frame.xBeads, 0)
        XCTAssertFalse(frame.facesLeft)
        frame = tick(&runtime, 2.3125)
        XCTAssertEqual(frame.frame, "walk_3")
        XCTAssertEqual(frame.xBeads, 2)
        frame = tick(&runtime, 4.01)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.xBeads, PetRuntime.walkBeads)
        XCTAssertEqual(frame.frame, "idle_1")
        frame = tick(&runtime, 9, roam: 20)
        XCTAssertEqual(frame.bit, .walk, "16 of 20 beads: the left side is farther")
        XCTAssertTrue(frame.facesLeft)
        XCTAssertEqual(tick(&runtime, 9.5, roam: 20).xBeads, 12)
        frame = tick(&runtime, 11.01, roam: 20)
        XCTAssertEqual(frame.xBeads, 0)
        XCTAssertTrue(frame.facesLeft, "it keeps facing the way it walked")
    }

    func testThePetNeverLeavesTheHabitat() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0.99]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 2).bit, .walk)
        XCTAssertEqual(tick(&runtime, 4.01).xBeads, 16)
        XCTAssertEqual(tick(&runtime, 5, roam: 10).xBeads, 10, "a narrower floor pulls the pet in")
        XCTAssertEqual(tick(&runtime, 6, roam: -5).xBeads, 0)
    }

    func testWithNoFloorToWalkThePetBlinksOrNaps() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0.5, 0.75, 0.5]))
        _ = tick(&runtime, 0, roam: 0)
        var frame = tick(&runtime, 2, roam: 0)
        XCTAssertEqual(frame.bit, .blink)
        XCTAssertEqual(frame.frame, "blink")
        XCTAssertEqual(frame.fps, 6)
        XCTAssertEqual(tick(&runtime, 2.1, roam: 0).bit, .blink)
        frame = tick(&runtime, 2.2, roam: 0)
        XCTAssertNil(frame.bit, "a blink is one cycle: 1/6 s")
        XCTAssertEqual(frame.frame, "idle_1")
        frame = tick(&runtime, 10.5, roam: 0)
        XCTAssertEqual(frame.bit, .nap)
        XCTAssertEqual(frame.frame, "sleep_1")
        XCTAssertEqual(frame.fps, 1.5)
        XCTAssertEqual(tick(&runtime, 11.2, roam: 0).frame, "sleep_2")
        XCTAssertEqual(tick(&runtime, 13.1, roam: 0).bit, .nap)
        frame = tick(&runtime, 13.2, roam: 0)
        XCTAssertNil(frame.bit, "a nap is two cycles: 2.67 s")
        XCTAssertEqual(frame.frame, "idle_1")
    }

    func testABitNeverCarriesOverAPause() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0.5, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 2).bit, .walk)
        XCTAssertEqual(tick(&runtime, 2.5).xBeads, 4)
        runtime.pause(at: t0 + 2.5)
        runtime.resume(at: t0 + 300)
        let frame = tick(&runtime, 300.1)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.xBeads, 4, "it stays where the walk stopped")
        XCTAssertEqual(runtime.clock.visibleTime(at: t0 + 300.1), 2.6, accuracy: 1e-6)
    }
}
