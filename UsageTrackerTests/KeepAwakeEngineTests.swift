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
            armed.arm(duration: 691_141, floorEnabled: true, now: t0, lidClosed: false),
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
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 + 7_200, reason: .deadline), failure: nil)
        )
    }

    /// Plan review P2a: the helper's deadline end is the deadline, the moment the app's
    /// local countdown (`KeepAwakeRules.effectiveState`) reports, not the tick that noticed
    /// it; the battery floor keeps the moment it fired.
    func testADeadlineEndCarriesTheDeadlineNotTheMomentItWasNoticed() {
        var late = engineArmed(for: 120)
        let output = late.tick(now: t0 + 150, lidClosed: false)
        XCTAssertEqual(output.state, .ended(at: t0 + 120, reason: .deadline))
        XCTAssertEqual(output.state, KeepAwakeRules.effectiveState(.armed(deadline: t0 + 120, floorEnabled: true), now: t0 + 150))
        var low = engineArmed(for: 7_200)
        XCTAssertEqual(
            low.power(onBattery: true, percent: 10, now: t0 + 600, lidClosed: false).state,
            .ended(at: t0 + 600, reason: .batteryFloor)
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
        XCTAssertEqual(engine.disarm(now: t0 + 90, lidClosed: false).state, .ended(at: t0 + 60, reason: .deadline))
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

    // MARK: - § Behaviour › Battery floor, § Behaviour › Floor switch while armed

    func testBelowTwentyFivePercentOnBatteryTheModeEnds() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.power(onBattery: true, percent: 24, now: t0 + 600, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 600, reason: .batteryFloor), failure: nil)
        )
    }

    func testTwentyFivePercentIsNotBelowTheFloor() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.power(onBattery: true, percent: 25, now: t0 + 600, lidClosed: false),
            Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil)
        )
    }

    func testOnTheChargerALowBatteryDoesNotEndTheMode() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(engine.power(onBattery: false, percent: 10, now: t0 + 600, lidClosed: false).state, .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    func testWithTheFloorOffTheBatteryDoesNotEndTheMode() {
        var engine = engineArmed(for: 7_200, floor: false)
        XCTAssertEqual(engine.power(onBattery: true, percent: 5, now: t0 + 600, lidClosed: false).state, .armed(deadline: t0 + 7_200, floorEnabled: false))
    }

    func testTurningTheFloorOnWhileLowOnBatteryEndsTheModeAtOnce() {
        var engine = engineArmed(for: 7_200, floor: false)
        _ = engine.power(onBattery: true, percent: 20, now: t0 + 600, lidClosed: false)
        XCTAssertEqual(
            engine.setFloor(enabled: true, now: t0 + 900, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 900, reason: .batteryFloor), failure: nil)
        )
    }

    func testTurningTheFloorOffKeepsTheDeadline() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.setFloor(enabled: false, now: t0 + 60, lidClosed: false),
            Out(sleepDisabled: true, sleepNow: false, state: .armed(deadline: t0 + 7_200, floorEnabled: false), failure: nil)
        )
    }

    func testTheFloorSwitchWhileIdleChangesNothing() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.setFloor(enabled: true, now: t0, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: nil)
        )
    }

    /// The flag was never on, so there is nothing to sleep from.
    func testApplyingBelowTheFloorEndsAtOnceAndNeverSleeps() {
        var engine = KeepAwakeEngine()
        _ = engine.power(onBattery: true, percent: 20, now: t0, lidClosed: true)
        XCTAssertEqual(
            engine.arm(duration: 7_200, floorEnabled: true, now: t0, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0, reason: .batteryFloor), failure: nil)
        )
    }

    func testALowBatteryWithTheLidClosedPutsTheMacToSleep() {
        var engine = engineArmed(for: 7_200)
        XCTAssertTrue(engine.power(onBattery: true, percent: 24, now: t0 + 600, lidClosed: true).sleepNow)
    }

    func testAPowerReadingAfterTheDeadlineEndsTheModeForTheDeadline() {
        var engine = engineArmed(for: 60)
        XCTAssertEqual(engine.power(onBattery: true, percent: 10, now: t0 + 90, lidClosed: false).state, .ended(at: t0 + 60, reason: .deadline))
    }

    // MARK: - § Behaviour › Survives the app, not a reboot; § Helper › Engine, start.
    // Review C5: whether to sleep comes from the flag as it was before the clear; the state
    // file only supplies the ended reason. Reviewer V3 (supersedes C5's "always clear"): only
    // the helper's own flag is cleared — the file says armed, or that the helper still owns
    // the flag (a clear that never read back, a sleep still owed).

    func testADaemonStartClearsAFlagThatDoesNotReadSet() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.start(persisted: nil, ownsFlag: false, flagWasSet: false, now: t0, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: nil)
        )
    }

    func testAStartAfterAnArmedModeEndsItAsRestarted() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.start(persisted: .armed(deadline: t0 + 3_600, floorEnabled: true), ownsFlag: false, flagWasSet: true, now: t0, lidClosed: false),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0, reason: .restarted), failure: nil)
        )
    }

    /// The block shows "Ended … · battery below 25 %" until the next Apply, even across a
    /// helper restart.
    func testAStartKeepsAnEndedModesReason() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.start(persisted: .ended(at: t0 - 60, reason: .batteryFloor), ownsFlag: false, flagWasSet: false, now: t0, lidClosed: false).state,
            .ended(at: t0 - 60, reason: .batteryFloor)
        )
    }

    /// D5: a crash with the lid closed must not leave the Mac awake in a bag.
    func testARestartThatFindsTheFlagSetWithTheLidClosedSleeps() {
        var engine = KeepAwakeEngine()
        XCTAssertTrue(
            engine.start(persisted: .armed(deadline: t0 + 3_600, floorEnabled: true), ownsFlag: false, flagWasSet: true, now: t0, lidClosed: true).sleepNow
        )
    }

    func testAStartWithTheFlagClearNeverSleeps() {
        var idle = KeepAwakeEngine()
        XCTAssertFalse(idle.start(persisted: .idle, ownsFlag: false, flagWasSet: false, now: t0, lidClosed: true).sleepNow)
        var ended = KeepAwakeEngine()
        XCTAssertFalse(ended.start(persisted: .ended(at: t0, reason: .deadline), ownsFlag: true, flagWasSet: false, now: t0, lidClosed: true).sleepNow)
        var armedButClear = KeepAwakeEngine()
        let output = armedButClear.start(persisted: .armed(deadline: t0 + 60, floorEnabled: true), ownsFlag: false, flagWasSet: false, now: t0, lidClosed: true)
        XCTAssertFalse(output.sleepNow)
        XCTAssertEqual(output.state, .ended(at: t0, reason: .restarted))
    }

    /// V3: Sleepless or `sudo pmset -a disablesleep 1` set the flag, and the helper started on
    /// an app launch with nothing armed on file. Not its flag: untouched, nothing ended, no
    /// sleep, even with the lid closed.
    func testAFlagSetWithNoModeOnFileIsNotTheHelpersAndIsLeftAlone() {
        for persisted in [nil, .idle] as [KeepAwakeState?] {
            var engine = KeepAwakeEngine()
            XCTAssertEqual(
                engine.start(persisted: persisted, ownsFlag: false, flagWasSet: true, now: t0, lidClosed: true),
                Out(sleepDisabled: nil, sleepNow: false, state: .idle, failure: nil),
                "\(String(describing: persisted))"
            )
        }
    }

    /// V3: an ended mode on file says nothing about a flag set since.
    func testAnEndedModeOnFileKeepsItsStateAndAFlagSetElsewhere() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.start(persisted: .ended(at: t0 - 60, reason: .batteryFloor), ownsFlag: false, flagWasSet: true, now: t0, lidClosed: true),
            Out(sleepDisabled: nil, sleepNow: false, state: .ended(at: t0 - 60, reason: .batteryFloor), failure: nil)
        )
    }

    /// A deadline whose clear failed, then a crash: the file says the helper still owns the
    /// flag, so the file's reason stays, the flag is cleared and the sleep is owed.
    func testAFlagLeftByAFailedClearKeepsTheFilesReasonAndSleeps() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(
            engine.start(persisted: .ended(at: t0 - 60, reason: .deadline), ownsFlag: true, flagWasSet: true, now: t0, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 - 60, reason: .deadline), failure: nil)
        )
    }

    func testAFlagSetWithTheLidOpenNeverSleeps() {
        var engine = KeepAwakeEngine()
        XCTAssertFalse(engine.start(persisted: nil, ownsFlag: true, flagWasSet: true, now: t0, lidClosed: false).sleepNow)
    }

    // MARK: - Review C3: launchd stopped the helper

    func testAStopEndsAnArmedModeWithoutEverSleeping() {
        var engine = engineArmed(for: 7_200)
        XCTAssertEqual(
            engine.stop(now: t0 + 60),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 60, reason: .stopped), failure: nil)
        )
    }

    func testAStopWhileIdleChangesNothing() {
        var engine = KeepAwakeEngine()
        XCTAssertEqual(engine.stop(now: t0), Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: nil))
    }
}
