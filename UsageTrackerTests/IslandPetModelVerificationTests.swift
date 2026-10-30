import Combine
import XCTest
@testable import Omelette

/// Verifier for notch-island spec 2026-10-29 § 3.5 "Animate only when" and "Jump from the island"
/// and § 3.8: the pet's visible clock follows the five conditions the island knows, in every order
/// and at the very moment each changes; a jump closes the island only if it is the latest of the
/// same open.
@MainActor
final class IslandPetModelVerificationTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func make(_ clock: Clock) -> IslandPetModel {
        IslandPetModel(keeper: PetKeeper(random: PetRandomFixture.sequence([0])), clock: { clock.now })
    }

    private enum Condition: CaseIterable {
        case open, habitat, window, display, lock, reduceMotion
    }

    private func apply(_ condition: Condition, on: Bool, to model: IslandPetModel) {
        switch condition {
        case .open: model.show(phase: on ? .open : .closing)
        case .habitat: model.setHabitatShown(on)
        case .window: model.setWindowVisible(on)
        case .display: model.setDisplayAwake(on)
        case .lock: model.setScreenLocked(!on)
        case .reduceMotion: model.setReduceMotion(!on)
        }
    }

    /// "On" means the condition holds for the pet: open, shown, visible, awake, unlocked, motion allowed.
    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    /// Whatever the order the six conditions come true in, the pet starts on the last one and not before.
    func testThePetStartsOnTheLastConditionInEveryOrder() {
        for order in permutations(Condition.allCases) {
            let clock = Clock(t0)
            let model = make(clock)
            // Display awake is the launch default; the other five are off. Turn the defaults to their bad side first.
            model.setDisplayAwake(false)
            model.setScreenLocked(true)
            model.setReduceMotion(true)
            for (index, condition) in order.enumerated() {
                clock.now = t0.addingTimeInterval(TimeInterval(index))
                apply(condition, on: true, to: model)
                let last = index == order.count - 1
                XCTAssertEqual(model.keeper.isAnimating, last, "\(order) after \(condition)")
                XCTAssertEqual(model.animates, last, "\(order) after \(condition)")
            }
            XCTAssertTrue(model.keeper.runtime.clock.isRunning)
            XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: t0.addingTimeInterval(100)), 100 - 5, "\(order): from the last condition")
        }
    }

    /// Whichever condition goes first, the pet stops at that moment and the time up to it is banked.
    func testAnyConditionGoingAwayStopsThePetAtThatMomentWithTheTimeBanked() {
        for condition in Condition.allCases {
            let clock = Clock(t0)
            let model = make(clock)
            for each in Condition.allCases { apply(each, on: true, to: model) }
            XCTAssertTrue(model.keeper.isAnimating, "\(condition): all conditions hold")
            clock.now = t0 + 7
            apply(condition, on: false, to: model)
            XCTAssertFalse(model.keeper.isAnimating, "\(condition)")
            XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: t0 + 500), 7, "\(condition): nothing after it went")
        }
    }

    /// A random walk over the six conditions and the clock: after every change the keeper runs exactly
    /// when the conditions allow, and the visible time is exactly the time they allowed.
    func testTheVisibleTimeIsTheTimeTheConditionsAllowedWhateverOrderTheyChanged() {
        var seed: UInt64 = 99
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let clock = Clock(t0)
        let model = make(clock)
        var shadow: [Condition: Bool] = [.open: false, .habitat: false, .window: false, .display: true, .lock: true, .reduceMotion: true]
        var allowed: TimeInterval = 0
        for step in 0..<3_000 {
            let dt = TimeInterval(next() % 40) * 0.25
            if shadow.values.allSatisfy({ $0 }) { allowed += dt }
            clock.now = clock.now.addingTimeInterval(dt)
            let condition = Condition.allCases[next() % Condition.allCases.count]
            let on = next() % 3 != 0
            shadow[condition] = on
            apply(condition, on: on, to: model)
            let expected = shadow.values.allSatisfy { $0 }
            XCTAssertEqual(model.keeper.isAnimating, expected, "step \(step) after \(condition) \(on)")
            XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: clock.now), allowed, accuracy: 1e-6, "step \(step)")
        }
    }

    /// Opening: the shape growing is not the island open, so a long entrance adds no visible time.
    func testTheEntranceAndTheExitAddNoVisibleTime() {
        let clock = Clock(t0)
        let model = make(clock)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
        model.show(phase: .opening)
        clock.now = t0 + 3
        XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: clock.now), 0)
        model.show(phase: .open)
        clock.now = t0 + 13
        model.show(phase: .closing)
        clock.now = t0 + 14
        model.show(phase: .closed)
        clock.now = t0 + 20
        XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: clock.now), 10)
    }

    /// Reduce Motion on at the moment of opening: nothing runs; switched off while open: it starts then.
    func testReduceMotionSwitchedOffWhileOpenStartsThePetAtThatMoment() {
        let clock = Clock(t0)
        let model = make(clock)
        model.setReduceMotion(true)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
        model.show(phase: .open)
        XCTAssertFalse(model.keeper.isAnimating)
        clock.now = t0 + 30
        model.setReduceMotion(false)
        XCTAssertTrue(model.keeper.isAnimating)
        XCTAssertEqual(model.keeper.runtime.clock.periodAge(at: t0 + 31), 1, "started at the switch, not at the open")
    }

    // MARK: - Jumps

    func testAJumpThatLandsAfterTheIslandClosedDoesNotCloseItAgain() {
        let model = make(Clock(t0))
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let landed = model.jumpStarted()
        model.islandClosed()
        landed()
        XCTAssertEqual(closes, 0, "dismissed while the jump was under way")
    }

    func testAReversedCloseIsANewGenerationEvenWithNoCloseInBetween() {
        let model = make(Clock(t0))
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let old = model.jumpStarted()
        model.islandOpened()
        old()
        XCTAssertEqual(closes, 0)
        let fresh = model.jumpStarted()
        fresh()
        XCTAssertEqual(closes, 1, "a jump of the new open still closes it")
    }

    func testAnOldLandingDoesNotSpoilTheNewOpensOwnJump() {
        let model = make(Clock(t0))
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let old = model.jumpStarted()
        model.islandClosed()
        model.islandOpened()
        let fresh = model.jumpStarted()
        old()
        XCTAssertEqual(closes, 0)
        fresh()
        XCTAssertEqual(closes, 1, "the stale landing neither closed nor cancelled the live one")
    }

    func testAJumpThatNeverLandsLeavesTheNextOnesLandingToClose() {
        let model = make(Clock(t0))
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        _ = model.jumpStarted()
        let second = model.jumpStarted()
        second()
        XCTAssertEqual(closes, 1)
    }

    func testALandingOfTheOlderJumpAfterTheNewerLandedDoesNothing() {
        let model = make(Clock(t0))
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let first = model.jumpStarted()
        let second = model.jumpStarted()
        second()
        first()
        XCTAssertEqual(closes, 1)
    }
}
