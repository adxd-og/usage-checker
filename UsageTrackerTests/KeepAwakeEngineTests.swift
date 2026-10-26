import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Design › Behaviour ("Timed only", "Ending while the lid is closed")
/// and § Helper › Engine: a value whose every input returns the flag to apply, whether to
/// sleep now and the state to report.
final class KeepAwakeEngineTests: XCTestCase {
    private typealias Out = KeepAwakeEngine.Output
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func engineArmed(for seconds: TimeInterval, floor: Bool = true) -> KeepAwakeEngine {
        var engine = KeepAwakeEngine()
        _ = engine.arm(duration: seconds, floorEnabled: floor, now: t0, lidClosed: false)
        return engine
    }

    func testArmingSetsTheFlagUntilTheDeadline() {
        var engine = KeepAwakeEngine()
        let output = engine.arm(duration: 7_200, floorEnabled: true, now: t0, lidClosed: false)
        XCTAssertEqual(output, Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        XCTAssertEqual(engine.state, output.state)
    }

    func testApplyWhileActiveReplacesTheDeadline() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.arm(duration: 1_800, floorEnabled: false, now: t0 + 600, lidClosed: true),
            Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 2_400, floorEnabled: false), failure: nil)
        )
    }

    func testADurationOutsideOneMinuteToSevenDaysIsRefusedAndChangesNothing() {
        var idle = KeepAwakeEngine()
        XCTAssertEqual(
            idle.arm(duration: 59, floorEnabled: true, now: t0, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: .invalidDuration)
        )
        var armed = engineArmed(for: 7_200)
        XCTAssertEqual(
            armed.arm(duration: 604_801, floorEnabled: true, now: t0, lidClosed: false),
            Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: .invalidDuration)
        )
    }

    func testATickBeforeTheDeadlineKeepsTheModeOn() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.tick(now: t0 + 7_199, lidClosed: true),
            Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil)
        )
    }

    func testTheDeadlineEndsTheModeAndClearsTheFlag() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.tick(now: t0 + 7_200, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 7_200, reason: .deadline), failure: nil)
        )
    }

    /// Spike step 5: clearing the flag with the lid closed leaves the Mac awake.
    func testEndingWithTheLidClosedPutsTheMacToSleep() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.tick(now: t0 + 7_230, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 + 7_230, reason: .deadline), failure: nil)
        )
    }

    func testCancelEndsTheModeAndClearsTheFlag() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.disarm(now: t0 + 60, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 60, reason: .cancelled), failure: nil)
        )
    }

    func testCancelWithTheLidClosedPutsTheMacToSleep() {
        var engine = engineArmed(for: 7_200)
        XCTAssertTrue(engine.disarm(now: t0 + 60, lidClosed: true).sleepNow)
    }

    func testACancelAfterTheDeadlineIsTheDeadlinesEnd() {
        var engine = engineArmed(for: 60)
        XCTAssertEqual(engine.disarm(now: t0 + 90, lidClosed: false).state, .ended(at: t0 + 90, reason: .deadline))
    }

    /// The reset path (spec § UI, Reset keep awake) disarms an idle helper to clear the flag.
    func testDisarmWhileIdleStillAsksForTheFlagCleared() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.disarm(now: t0, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: nil)
        )
    }

    func testAnEndedModeStaysEndedAndNeverSleepsTwice() {
        var engine = engineArmed(for: 60)
        _ = engine.tick(now: t0 + 60, lidClosed: true)
        XCTAssertEqual(
            engine.tick(now: t0 + 120, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 60, reason: .deadline), failure: nil)
        )
        XCTAssertEqual(engine.disarm(now: t0 + 180, lidClosed: true).state, .ended(at: t0 + 60, reason: .deadline))
    }

    func testTheTickComesEveryMinuteAndLandsOnTheDeadline() {
        let engine = engineArmed(for: 3_600)
        XCTAssertEqual(engine.nextTick(now: t0), t0 + 60)
        XCTAssertEqual(engine.nextTick(now: t0 + 3_570), t0 + 3_600)
    }

    func testNoTickIsNeededWhileIdleOrEnded() {
        XCTAssertNil(KeepAwakeEngine().nextTick(now: t0))
        var engine = engineArmed(for: 60)
        _ = engine.tick(now: t0 + 60, lidClosed: false)
        XCTAssertNil(engine.nextTick(now: t0 + 60))
    }
}
