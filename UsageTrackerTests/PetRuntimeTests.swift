import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime and § 3.9 `PetRuntime`: each pose plays its own
/// animation; while the mood loops (Idle, and Agent working by the owner's ruling of
/// 2026-10-30) the idle loop plays a bit (walk, blink, nap; sitting is the idle pose) at most
/// every 20–40 s of visible open time, never in an open's first 1.5 s, never while the pointer
/// is over the right column or a field has focus; motion never leaves the habitat and moves in
/// whole beads; a pause ends a bit; a still pet shows its current mood's still.
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
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5]))
        XCTAssertNil(tick(&runtime, 0).bit)
        XCTAssertNil(tick(&runtime, 19.5).bit)
        XCTAssertEqual(tick(&runtime, 20).bit, .blink)
    }

    func testNoBitInTheFirstSecondAndAHalfOfAnOpen() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5]))
        runtime.resume(at: t0)
        runtime.pause(at: t0 + 30)
        runtime.resume(at: t0 + 100)
        XCTAssertNil(tick(&runtime, 100).bit)
        XCTAssertNil(tick(&runtime, 101.4).bit, "30 s seen, past the deadline, but the open is 1.4 s old")
        XCTAssertEqual(tick(&runtime, 101.5).bit, .blink)
    }

    func testBitsPlayOnlyWhileTheMoodLoops() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5]))
        XCTAssertNil(tick(&runtime, 0, pose: .look, loops: false).bit)
        XCTAssertNil(tick(&runtime, 25, pose: .look, loops: false).bit, "an alert: the pet holds still")
        XCTAssertNil(tick(&runtime, 26, pose: .sleep, loops: false).bit, "keep awake at night: it sleeps")
        XCTAssertEqual(tick(&runtime, 27).bit, .blink, "calm again (idle or agents working), the bit due since 20 s plays")
    }

    func testABitWaitsWhileThePointerIsOverTheContentOrAFieldHasFocus() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertNil(tick(&runtime, 20, activity: PetUserActivity(pointerOverContent: true)).bit)
        XCTAssertNil(tick(&runtime, 21, activity: PetUserActivity(fieldFocused: true)).bit)
        XCTAssertEqual(tick(&runtime, 22).bit, .blink)
    }

    func testARunningBitStopsWhenTheUserTurnsToTheContent() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .walk)
        let frame = tick(&runtime, 20.25, activity: PetUserActivity(pointerOverContent: true))
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.frame, "idle_1")
    }

    func testAWalkMovesABeadAFrameTowardTheFartherEdge() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0, 0]))
        _ = tick(&runtime, 0)
        var frame = tick(&runtime, 20)
        XCTAssertEqual(frame.bit, .walk)
        XCTAssertEqual(frame.frame, "walk_1")
        XCTAssertEqual(frame.fps, 8)
        XCTAssertEqual(frame.xBeads, 0)
        XCTAssertFalse(frame.facesLeft)
        frame = tick(&runtime, 20.3125)
        XCTAssertEqual(frame.frame, "walk_3")
        XCTAssertEqual(frame.xBeads, 2)
        frame = tick(&runtime, 22.01)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.xBeads, PetRuntime.walkBeads)
        XCTAssertEqual(frame.frame, "idle_1")
        frame = tick(&runtime, 40, roam: 20)
        XCTAssertEqual(frame.bit, .walk, "16 of 20 beads: the left side is farther")
        XCTAssertTrue(frame.facesLeft)
        XCTAssertEqual(tick(&runtime, 40.5, roam: 20).xBeads, 12)
        frame = tick(&runtime, 42.01, roam: 20)
        XCTAssertEqual(frame.xBeads, 0)
        XCTAssertTrue(frame.facesLeft, "it keeps facing the way it walked")
    }

    func testThePetNeverLeavesTheHabitat() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.99]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .walk)
        XCTAssertEqual(tick(&runtime, 22.01).xBeads, 16)
        XCTAssertEqual(tick(&runtime, 23, roam: 10).xBeads, 10, "a narrower floor pulls the pet in")
        XCTAssertEqual(tick(&runtime, 24, roam: -5).xBeads, 0)
    }

    func testWithNoFloorToWalkThePetBlinksOrNaps() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.75, 0.5]))
        _ = tick(&runtime, 0, roam: 0)
        var frame = tick(&runtime, 20, roam: 0)
        XCTAssertEqual(frame.bit, .blink)
        XCTAssertEqual(frame.frame, "blink")
        XCTAssertEqual(frame.fps, 6)
        XCTAssertEqual(tick(&runtime, 20.1, roam: 0).bit, .blink)
        frame = tick(&runtime, 20.2, roam: 0)
        XCTAssertNil(frame.bit, "a blink is one cycle: 1/6 s")
        XCTAssertEqual(frame.frame, "idle_1")
        frame = tick(&runtime, 50, roam: 0)
        XCTAssertEqual(frame.bit, .nap)
        XCTAssertEqual(frame.frame, "sleep_1")
        XCTAssertEqual(frame.fps, 1.5)
        XCTAssertEqual(tick(&runtime, 50.7, roam: 0).frame, "sleep_2")
        XCTAssertEqual(tick(&runtime, 52.6, roam: 0).bit, .nap)
        frame = tick(&runtime, 52.7, roam: 0)
        XCTAssertNil(frame.bit, "a nap is two cycles: 2.67 s")
        XCTAssertEqual(frame.frame, "idle_1")
    }

    func testABitNeverCarriesOverAPause() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .walk)
        XCTAssertEqual(tick(&runtime, 20.5).xBeads, 4)
        runtime.pause(at: t0 + 20.5)
        runtime.resume(at: t0 + 300)
        let frame = tick(&runtime, 300.1)
        XCTAssertNil(frame.bit)
        XCTAssertEqual(frame.xBeads, 4, "it stays where the walk stopped")
        XCTAssertEqual(runtime.clock.visibleTime(at: t0 + 300.1), 20.6, accuracy: 1e-6)
    }
}
