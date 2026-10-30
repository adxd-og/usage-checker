import XCTest
@testable import Omelette

/// Second verification of notch-island spec 2026-10-29 § 3.5 with the owner's note of
/// 2026-10-30 (first look at the pet): a bit every 7–10 s of visible time, an open's first bit
/// 2–4 s into it, a pat in Agent working like a pat when idle. Gaps the first verification left:
/// every open past 4 s shows a bit across many short opens, a pat in one open against the next open's first bit,
/// and the click in Agent working end to end through the keeper.
@MainActor
final class PetRuntimeVerification2Tests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let animations = PetRuntimeFixture.animations

    private final class Lcg {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

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

    /// Calm opens of 0.3 … 14 s with closed gaps of hours between them (nothing busy, no pat, a
    /// mood that loops): an open that lasts past 4 s shows a bit by then, and no bit is within an
    /// open's first 1.5 s. Visible time between bits has no bound across opens: an open shorter
    /// than the quiet start adds time with no chance of a bit.
    func testAcrossManyShortCalmOpensNoBitIsLateAndNoneIsEarly() {
        for seed in [3, 11, 99] as [UInt64] {
            let world = Lcg(seed)
            var runtime = PetRuntime(random: PetRandom(unit: { [chance = Lcg(seed ^ 0x5EED)] in chance.next() }))
            let dt = 0.0625
            var wall = 0.0
            var previousBit: PetBit?
            var failures: [String] = []
            for open in 0..<400 {
                wall += 3_600 * (1 + world.next() * 10)
                let length = 0.3 + world.next() * 14
                runtime.resume(at: t0 + wall)
                var shownThisOpen = false
                var step = 0.0
                while step <= length {
                    let frame = runtime.tick(
                        at: t0 + wall + step, pose: .idle, loops: true, activity: .none,
                        animations: animations, roamBeads: 65
                    )
                    let started = frame.bit != nil && frame.bit != previousBit
                    if started {
                        if step < 1.5 - 1e-9 { failures.append("open \(open): a bit \(step) s in") }
                        shownThisOpen = true
                    }
                    if !shownThisOpen, step > 4 + dt + 1e-9 {
                        failures.append("open \(open): no bit by \(step) s")
                        shownThisOpen = true
                    }
                    previousBit = frame.bit
                    step += dt
                }
                runtime.pause(at: t0 + wall + length)
                previousBit = nil
                wall += length
            }
            XCTAssertEqual(Array(failures.prefix(10)), [], "seed \(seed)")
        }
    }

    /// A pat early in one open puts the loop off 7–10 s, but the next open's first bit is still
    /// due 2–4 s into that open: the pat does not eat it.
    func testAPatInOneOpenDoesNotDelayTheNextOpensFirstBit() {
        // clock deadline 9.9, open one's first-bit draw 0.99 (3.98 s), pat's spacing 7, open two 0.5 (3 s)
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.9, 0.99, 0, 0.5]))
        runtime.resume(at: t0)
        runtime.pat(at: t0 + 0.5)
        XCTAssertEqual(runtime.clock.nextBitAt, 7.5, accuracy: 1e-9)
        runtime.pause(at: t0 + 1)
        runtime.resume(at: t0 + 5_000)
        XCTAssertEqual(runtime.clock.nextBitAt, 1 + 3, accuracy: 1e-9, "1 s seen, 3 s into this open")
        XCTAssertNil(
            runtime.tick(
                at: t0 + 5_002.9, pose: .idle, loops: true, activity: .none, animations: animations, roamBeads: 65
            ).bit
        )
        XCTAssertNotNil(
            runtime.tick(
                at: t0 + 5_003, pose: .idle, loops: true, activity: .none, animations: animations, roamBeads: 65
            ).bit
        )
    }

    /// A pat while the gate is off (the keeper does not guard it) banks nothing and starts no
    /// period; the next open's first bit is still 2–4 s in.
    func testAPatWhileClosedLeavesTheNextOpensFirstBitAt2To4Seconds() {
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0.9, 0.5, 0.5, 0.5]))
        keeper.pat(at: t0)
        XCTAssertFalse(keeper.runtime.clock.isRunning)
        XCTAssertEqual(keeper.runtime.clock.visibleTime(at: t0 + 100), 0)
        keeper.setAnimating(true, at: t0 + 100)
        let idle = presentation(.idle)
        XCTAssertNil(keeper.frame(at: t0 + 102.9, presentation: idle, animations: animations, roamBeads: 65)?.bit)
        XCTAssertNotNil(keeper.frame(at: t0 + 103, presentation: idle, animations: animations, roamBeads: 65)?.bit)
    }

    /// The click in Agent working, through the rule and the keeper: the effect is a pat, the
    /// heart shows for 1.2 s over the working cat, no bit starts under it, and the next bit is
    /// 7–10 s of visible time after the click, not the open's 2–4 s.
    func testAPatInAgentWorkingShowsAHeartAndPutsTheNextBitOff() {
        let working = presentation(.working(count: 3))
        XCTAssertEqual(
            PetActionRules.effects(of: working.action, page: .provider("claude"), providers: ["claude", "codex"]), [.pat]
        )
        XCTAssertTrue(PetActionRules.isActionable(working.action))
        XCTAssertTrue(working.loops)
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0.9, 0, 0.5, 0.5]))
        keeper.setAnimating(true, at: t0)
        func frame(_ seconds: TimeInterval) -> PetFrame? {
            keeper.frame(at: t0 + seconds, presentation: working, animations: animations, roamBeads: 65)
        }
        XCTAssertNil(frame(1.6)?.bit)
        keeper.pat(at: t0 + 1.75)
        var heart = frame(1.8)
        XCTAssertEqual(heart?.showsHeart, true)
        XCTAssertNil(heart?.bit, "the first-bit slot at 2 s moved to 8.5 s after the click")
        heart = frame(2.9)
        XCTAssertEqual(heart?.showsHeart, true)
        XCTAssertNil(heart?.bit)
        let after = frame(2.95)
        XCTAssertEqual(after?.showsHeart, false)
        XCTAssertNil(after?.bit)
        XCTAssertNil(frame(1.75 + 8.5 - 0.25)?.bit)
        XCTAssertNotNil(frame(1.75 + 8.5)?.bit)
    }
}
