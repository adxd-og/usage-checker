import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 Runtime and § 3.8 battery, with the
/// owner's notes of 2026-10-30 (bits also run in Agent working; the stretch plays `look`; a bit
/// every 7–10 s, an open's first 2–4 s into it): long randomised runs of opens, closes, busy
/// pointers, mood changes, pats and polls against each shipped pet's real animations, checking
/// the invariants rather than one scenario each.
final class PetRuntimeVerificationTests: XCTestCase {
    private final class Lcg {
        private var state: UInt64

        init(_ seed: UInt64) {
            state = seed
        }

        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        func below(_ count: Int) -> Int { min(count - 1, Int(next() * Double(count))) }
    }

    private let t0 = PetRuntimeFixture.t0
    private let dt = 0.0625

    private struct Mood {
        let pose: PetPose
        let loops: Bool
    }

    private let moods = [
        Mood(pose: .idle, loops: true), Mood(pose: .idle, loops: true),
        Mood(pose: .look, loops: false), Mood(pose: .sleep, loops: false),
    ]

    private func claude(window: String, resetsAt: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: window, label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], state: state, at: t0)
    }

    /// Runs `seconds` of app time; `calm`: one open, no busy pointer, one mood, no pats, no
    /// polls (the spacing's upper bound holds only then). An open nothing blocked (no busy
    /// pointer, no mood that holds still, no pat) has shown a bit by 4 s, in every run. Returns
    /// the visible times at which bits and stretches started.
    @discardableResult
    private func simulate(
        _ manifest: PetManifest, seed: UInt64, seconds: Double, calm: Bool, file: StaticString = #filePath, line: UInt = #line
    ) -> (bitStarts: [Double], stretches: Int, walks: Int) {
        let animations = manifest.animations
        let fpsOfAll = Set(PetAnimationName.allCases.map { animations[$0].fps })
        let world = Lcg(seed)
        let chance = Lcg(seed ^ 0xABCDEF)
        var runtime = PetRuntime(random: PetRandom { chance.next() })

        var open = false
        var openedAt = 0.0
        var banked = 0.0
        var nextToggle = 0.0
        var roam = 65
        var mood = moods[0]
        var nextMood = 0.0
        var busy = PetUserActivity.none
        var nextBusy = 5.0
        var nextPoll = 40.0
        var feeds = 0
        var pending = false
        var previousBit: PetBit?
        var startedThisOpen = false
        var blockedThisOpen = false
        var starts: [Double] = []
        var stretches = 0
        var walks = 0
        var walk: (x0: Int, left: Bool, roam: Int)?
        var previousX: Int?

        var failures: [String] = []
        func expect(_ holds: Bool, _ message: @autoclosure () -> String) {
            if !holds, failures.count < 20 { failures.append(message()) }
        }

        var tick = 0
        while Double(tick) * dt < seconds {
            let t = Double(tick) * dt
            let now = t0 + t
            tick += 1

            if t >= nextToggle {
                if open {
                    runtime.pause(at: now)
                    banked += t - openedAt
                    open = false
                    previousBit = nil
                    walk = nil
                    nextToggle = t + (calm ? 1e9 : 1 + world.next() * 120)
                } else {
                    runtime.resume(at: now)
                    openedAt = t
                    open = true
                    startedThisOpen = false
                    blockedThisOpen = false
                    roam = calm ? 65 : [0, 1, 2, 5, 16, 17, 33, 65][world.below(8)]
                    nextToggle = t + (calm ? 1e9 : 0.5 + world.next() * 60)
                    previousX = nil
                }
            }
            if !calm {
                if t >= nextMood { mood = moods[world.below(moods.count)]; nextMood = t + 30 + world.next() * 60 }
                if t >= nextBusy {
                    busy = PetUserActivity(pointerOverContent: world.next() < 0.3, fieldFocused: world.next() < 0.1)
                    nextBusy = t + 1 + world.next() * 15
                }
                if t >= nextPoll {
                    feeds += 1
                    let window = "w\(feeds)"
                    let passed = now.addingTimeInterval(-1)
                    runtime.observe([claude(window: window, resetsAt: passed)], now: now)
                    if world.next() < 0.5 {
                        runtime.observe([claude(window: window, resetsAt: passed.addingTimeInterval(18_000), state: .notRunning)], now: now)
                    } else {
                        runtime.observe([claude(window: window, resetsAt: passed.addingTimeInterval(18_000))], now: now)
                        pending = true
                    }
                    nextPoll = t + 20 + world.next() * 200
                }
            }
            guard open else { continue }

            if !calm, mood.loops, mood.pose == .idle, world.next() < 0.003 {
                runtime.pat(at: now)
                blockedThisOpen = true
            }
            let activity = calm ? PetUserActivity.none : busy
            if activity.isBusy || !mood.loops { blockedThisOpen = true }
            let frame = runtime.tick(
                at: now, pose: mood.pose, loops: mood.loops, activity: activity,
                animations: animations, roamBeads: roam
            )
            let visible = banked + (t - openedAt)
            let context = "\(manifest.id) seed \(seed) t=\(t)"

            expect(manifest.frames[frame.frame] != nil, "frame exists: \(context)")
            expect(fpsOfAll.contains(frame.fps), "fps \(context)")
            expect(frame.xBeads >= 0 && frame.xBeads <= roam, "inside the habitat (\(frame.xBeads) of \(roam)): \(context)")
            if let bit = frame.bit {
                expect(animations[bit.animation].frames.contains(frame.frame), "\(bit) frame \(context)")
                expect(frame.fps == animations[bit.animation].fps, "\(bit) fps \(context)")
                expect(mood.loops, "no bit in an alert or asleep: \(context)")
                expect(!activity.isBusy, "no bit while the pointer is over the content or a field has focus: \(context)")
            } else {
                expect(animations[mood.pose.animation].frames.contains(frame.frame), "pose frames: \(context)")
                expect(frame.fps == animations[mood.pose.animation].fps, "pose fps \(context)")
            }
            if frame.showsHeart { expect(mood.loops, "heart only in a calm mood: \(context)") }

            let started = frame.bit != nil && frame.bit != previousBit
            if started, let bit = frame.bit {
                if startedThisOpen, let last = starts.last {
                    expect(visible - last >= 7 - 1e-9, "bit spacing \(visible - last): \(context)")
                    if calm { expect(visible - last <= 10 + dt + 1e-9, "bit spacing \(visible - last): \(context)") }
                }
                expect(t - openedAt >= 1.5 - 1e-9, "not in an open's first 1.5 s: \(context)")
                startedThisOpen = true
                starts.append(visible)
                if bit == .stretch {
                    stretches += 1
                    expect(pending, "a stretch needs a reset seen in a live poll: \(context)")
                    pending = false
                    expect(frame.frame == animations.look.frames[0], "stretch plays look: \(context)")
                }
                if bit == .walk {
                    walks += 1
                    walk = (frame.xBeads, frame.facesLeft, roam)
                    expect(frame.facesLeft == (frame.xBeads * 2 > roam), "toward the farther edge: \(context)")
                } else {
                    walk = nil
                }
            }
            if frame.bit == .walk, let current = walk {
                expect(abs(frame.xBeads - current.x0) <= PetRuntime.walkBeads, "walk length: \(context)")
                expect(current.left ? frame.xBeads <= current.x0 : frame.xBeads >= current.x0, "walk direction: \(context)")
                expect(frame.facesLeft == current.left, "mirroring: \(context)")
                if let previousX, !started {
                    expect(abs(frame.xBeads - previousX) <= 1, "a bead a frame: \(context)")
                }
            }
            if frame.bit == nil { walk = nil }
            if !startedThisOpen, !blockedThisOpen {
                expect(t - openedAt <= 4 + dt + 1e-9, "an open's first bit by 4 s: \(context)")
            }
            previousX = frame.xBeads
            previousBit = frame.bit
        }
        XCTAssertEqual(failures, [], file: file, line: line)
        return (starts, stretches, walks)
    }

    func testEveryShippedPetPlaysOnlyItsOwnFramesAndStaysInsideTheHabitatThroughLongRandomRuns() throws {
        let library = PetLibrary.bundled()
        XCTAssertEqual(library.animalIDs, ["cat", "dog", "duck", "raccoon"])
        var stretches = 0
        var walks = 0
        var bits = 0
        for (index, id) in library.animalIDs.enumerated() {
            let manifest = try XCTUnwrap(library.manifests[id])
            for seed in 1...3 {
                let result = simulate(manifest, seed: UInt64(index * 100 + seed), seconds: 3_600, calm: false)
                stretches += result.stretches
                walks += result.walks
                bits += result.bitStarts.count
            }
        }
        XCTAssertGreaterThan(bits, 50, "the runs must exercise bits")
        XCTAssertGreaterThan(walks, 5, "the runs must exercise walks")
        XCTAssertGreaterThan(stretches, 0, "the runs must exercise the stretch")
    }

    func testInACalmOpenABitStartsEvery7To10SecondsOfVisibleTimeForEveryPet() throws {
        let library = PetLibrary.bundled()
        for id in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[id])
            let result = simulate(manifest, seed: 7, seconds: 3_600, calm: true)
            let first = try XCTUnwrap(result.bitStarts.first, id)
            XCTAssertGreaterThanOrEqual(first, 2 - 1e-9, id)
            XCTAssertLessThanOrEqual(first, 4 + dt + 1e-9, id)
            XCTAssertGreaterThan(result.bitStarts.count, 350, "3,600 s at no more than 10 s each \(id)")
            XCTAssertLessThan(result.bitStarts.count, 515, "3,600 s at no less than 7 s each \(id)")
        }
    }

    func testTheStillIsTheCurrentPosesWhateverTheLastMoodWas() throws {
        let library = PetLibrary.bundled()
        for id in library.animalIDs {
            let manifest = try XCTUnwrap(library.manifests[id])
            for pose in PetPose.allCases {
                let frame = PetRuntime.still(pose: pose, stills: manifest.still)
                XCTAssertEqual(frame, manifest.still[pose], id)
                XCTAssertNotNil(manifest.frames[frame], "\(id) \(pose)")
            }
        }
    }

    func testWithTheGateOffThereIsNoTimelineWhateverTheRate() {
        for bits in 0..<32 {
            let conditions = PetAnimationGate.Conditions(
                surfaceOpen: bits & 1 != 0, windowVisible: bits & 2 != 0, displayAwake: bits & 4 != 0,
                screenLocked: bits & 8 != 0, reduceMotion: bits & 16 != 0
            )
            for fps in [0.5, 1, 8, 12] {
                if PetAnimationGate.animates(conditions) {
                    XCTAssertEqual(PetAnimationGate.framePeriod(conditions, fps: fps), 1 / fps)
                } else {
                    XCTAssertNil(PetAnimationGate.framePeriod(conditions, fps: fps), "\(conditions)")
                }
            }
        }
    }

    /// A walk is as long as the floor it has, a bead a frame: with 10 beads of floor it ends
    /// after 10 frames, not after the 16 a longer floor allows (the pet never walks on the spot
    /// against the edge).
    func testAWalkWithLessFloorThanSixteenBeadsEndsWhenItReachesTheEdge() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0, 0.5]))
        func tick(_ seconds: TimeInterval) -> PetFrame {
            runtime.tick(
                at: t0 + seconds, pose: .idle, loops: true, activity: .none,
                animations: PetRuntimeFixture.animations, roamBeads: 10
            )
        }
        _ = tick(0)
        XCTAssertEqual(tick(2).bit, .walk)
        let near = tick(3.1)
        XCTAssertEqual(near.bit, .walk)
        XCTAssertEqual(near.xBeads, 8)
        let done = tick(3.3)
        XCTAssertNil(done.bit, "10 beads at 8 fps: 1.25 s")
        XCTAssertEqual(done.xBeads, 10)
    }

    func testAPatAndACollapsedIslandAddNothingToTheVisibleClock() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0.5, 0.5]))
        runtime.resume(at: t0)
        runtime.pause(at: t0 + 10)
        XCTAssertEqual(runtime.clock.visibleTime(at: t0 + 1_000), 10, "closed time is not visible time")
        runtime.resume(at: t0 + 2_000)
        runtime.pat(at: t0 + 2_005)
        XCTAssertEqual(runtime.clock.nextBitAt, 15 + 8.5, accuracy: 1e-9, "7–10 s of visible time from the pat")
    }
}
