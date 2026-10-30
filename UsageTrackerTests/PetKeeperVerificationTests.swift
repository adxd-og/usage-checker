import Combine
import XCTest
@testable import Omelette

/// Verifier for notch-island spec 2026-10-29 § 3.5 Runtime (one stretch per live reset, waiting
/// for the island's next open with no wall-clock expiry; bits on visible open time, an open's
/// first 2–4 s into it) and § 3.8
/// (the habitat's `TimelineView` closure may run twice for one tick): the keeper's `frame(at:)`
/// is safe to evaluate twice at the same instant, and a waiting stretch survives closed hours,
/// several opens and a pat.
@MainActor
final class PetKeeperVerificationTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let animations = PetRuntimeFixture.animations

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func presentation(_ mood: PetMood) -> PetMoodPresentation {
        PetMoodRules.presentation(
            of: mood, petName: "Cat", mode: .used, now: t0, calendar: utc, locale: Locale(identifier: "en_GB")
        )
    }

    private func claude(resetsAt: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], state: state, at: t0)
    }

    private final class Lcg {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private final class Box {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// A keeper whose chance, clock and polls are all driven from the test.
    @MainActor private struct Rig {
        let keeper: PetKeeper
        let polls = PassthroughSubject<[ServiceSnapshot], Never>()
        let pollClock: Box

        init(draws: PetRandom, seen: Date) {
            let box = Box(seen)
            pollClock = box
            keeper = PetKeeper(random: draws, clock: { box.now })
            keeper.watch(polls)
        }
    }

    // MARK: - The timeline closure runs twice

    /// A walk of 900 ticks with pats, polls that show resets, gate flips, busy users and moods
    /// that loop and do not: a keeper ticked twice at every instant does what a keeper ticked once
    /// does — same frames, same state, same chance consumed.
    func testTickingTwiceAtTheSameInstantChangesNothing() {
        for seed in [1, 7, 42, 2026] as [UInt64] {
            let once = Rig(draws: PetRandom(unit: { [lcg = Lcg(seed)] in lcg.next() }), seen: t0)
            let twice = Rig(draws: PetRandom(unit: { [lcg = Lcg(seed)] in lcg.next() }), seen: t0)
            let script = Lcg(seed &+ 1000)
            let first = t0.addingTimeInterval(-3_600)
            for rig in [once, twice] {
                rig.pollClock.now = t0.addingTimeInterval(-3_660)
                rig.polls.send([claude(resetsAt: first)])
                rig.pollClock.now = t0.addingTimeInterval(100 * 86_400)
            }
            var activity = PetUserActivity.none
            once.keeper.activity = { activity }
            twice.keeper.activity = { activity }
            var now = t0
            var resetsSent = 0
            let moods: [PetMood] = [.idle, .idle, .idle, .working(count: 2), .nothingOn]
            for step in 0..<900 {
                now = now.addingTimeInterval([0.0625, 0.125, 0.25, 0.5, 1.5][Int(script.next() * 5)])
                let roll = script.next()
                activity = PetUserActivity(pointerOverContent: roll < 0.1, fieldFocused: roll > 0.95)
                if roll > 0.5 && roll < 0.53 {
                    for rig in [once, twice] { rig.keeper.setAnimating(!rig.keeper.isAnimating, at: now) }
                }
                if roll > 0.6 && roll < 0.62 {
                    for rig in [once, twice] { rig.keeper.pat(at: now) }
                }
                if roll > 0.7 && roll < 0.73 {
                    resetsSent += 1
                    let next = first.addingTimeInterval(TimeInterval(resetsSent) * 5 * 3_600)
                    for rig in [once, twice] { rig.polls.send([claude(resetsAt: next)]) }
                }
                let shown = presentation(moods[Int(script.next() * Double(moods.count))])
                let roam = [0, 65, 115][Int(script.next() * 3)]
                let a = once.keeper.frame(at: now, presentation: shown, animations: animations, roamBeads: roam)
                let b1 = twice.keeper.frame(at: now, presentation: shown, animations: animations, roamBeads: roam)
                let b2 = twice.keeper.frame(at: now, presentation: shown, animations: animations, roamBeads: roam)
                XCTAssertEqual(b1, a, "seed \(seed) step \(step): the first evaluation")
                XCTAssertEqual(b2, a, "seed \(seed) step \(step): the second evaluation")
                XCTAssertEqual(twice.keeper.runtime.xBeads, once.keeper.runtime.xBeads, "seed \(seed) step \(step)")
                XCTAssertEqual(twice.keeper.runtime.stretchSeenAt, once.keeper.runtime.stretchSeenAt, "seed \(seed) step \(step)")
                XCTAssertEqual(twice.keeper.runtime.clock, once.keeper.runtime.clock, "seed \(seed) step \(step)")
            }
        }
    }

    // MARK: - The stretch waits

    /// Seen with the island closed; opened hours later for a second, closed again for a day,
    /// opened again: the stretch plays when the visible time reaches the slot (3 s, over two
    /// opens), not before, and never because wall-clock time passed.
    func testAStretchSeenWhileClosedWaitsAcrossHoursAndShortOpensForVisibleTimeAlone() {
        let rig = Rig(draws: PetRandomFixture.sequence([0, 0.5, 0.5]), seen: t0)
        let reset = t0.addingTimeInterval(-3_600)
        rig.pollClock.now = t0.addingTimeInterval(-3_660)
        rig.polls.send([claude(resetsAt: reset)])
        rig.pollClock.now = t0
        rig.polls.send([claude(resetsAt: reset.addingTimeInterval(5 * 3_600))])
        XCTAssertEqual(rig.keeper.runtime.stretchSeenAt, t0, "a live poll with the island never opened")
        let idle = presentation(.idle)
        func frame(_ at: Date) -> PetFrame? {
            rig.keeper.frame(at: at, presentation: idle, animations: animations, roamBeads: 65)
        }
        let open1 = t0.addingTimeInterval(6 * 3_600)
        XCTAssertNil(frame(open1), "closed: no frame at all")
        rig.keeper.setAnimating(true, at: open1)
        XCTAssertNil(frame(open1.addingTimeInterval(0.9))?.bit)
        rig.keeper.setAnimating(false, at: open1.addingTimeInterval(1))
        let open2 = t0.addingTimeInterval(36 * 3_600)
        rig.keeper.setAnimating(true, at: open2)
        XCTAssertNil(frame(open2.addingTimeInterval(1.9))?.bit, "1 s of the first open and 1.9 s of this one: not 3 yet")
        XCTAssertEqual(frame(open2.addingTimeInterval(2))?.bit, .stretch, "3 s of visible time over two opens")
        XCTAssertNil(rig.keeper.runtime.stretchSeenAt)
    }

    /// A pat puts the next slot 7–10 s off; the stretch that was waiting is not lost with it.
    func testAPatDelaysAWaitingStretchButDoesNotDropIt() {
        let rig = Rig(draws: PetRandomFixture.sequence([0, 0, 0.5]), seen: t0)
        let reset = t0.addingTimeInterval(-3_600)
        rig.pollClock.now = t0.addingTimeInterval(-3_660)
        rig.polls.send([claude(resetsAt: reset)])
        rig.pollClock.now = t0
        rig.polls.send([claude(resetsAt: reset.addingTimeInterval(5 * 3_600))])
        let idle = presentation(.idle)
        rig.keeper.setAnimating(true, at: t0)
        _ = rig.keeper.frame(at: t0 + 1, presentation: idle, animations: animations, roamBeads: 65)
        rig.keeper.pat(at: t0 + 1)
        XCTAssertEqual(rig.keeper.runtime.stretchSeenAt, t0, "still waiting")
        XCTAssertNil(rig.keeper.frame(at: t0 + 9.4, presentation: idle, animations: animations, roamBeads: 65)?.bit)
        XCTAssertEqual(
            rig.keeper.frame(at: t0 + 9.5, presentation: idle, animations: animations, roamBeads: 65)?.bit, .stretch,
            "1 s of visible time and the pat's 8.5"
        )
    }

    /// The seed a subscription delivers and a retained provider's later reading both bring nothing.
    func testTheSeedAndARetainedRefreshBringNoStretchThroughTheKeeper() {
        let reset = t0.addingTimeInterval(-3_600)
        let seed = CurrentValueSubject<[ServiceSnapshot], Never>([claude(resetsAt: reset)])
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0]), clock: { self.t0 })
        keeper.watch(seed)
        seed.send([claude(resetsAt: reset.addingTimeInterval(5 * 3_600), state: .notRunning)])
        seed.send([])
        XCTAssertNil(keeper.runtime.stretchSeenAt)
    }
}
