import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Rule: the engine's thermal input ends an armed
/// mode as `overheated` through the existing output (flag cleared, `sleepNow` with the lid
/// closed); the guard's switch is an input of its own and every Apply turns it on (§ Plan
/// decisions accepted by the session, item 6, amended 2026-11-20); a new mode counts its own
/// hot minute.
final class KeepAwakeThermalEngineTests: XCTestCase {
    private typealias Out = KeepAwakeEngine.Output
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func engineArmed(for seconds: TimeInterval = 7_200) -> KeepAwakeEngine {
        var engine = KeepAwakeEngine()
        _ = engine.arm(duration: seconds, floorEnabled: true, now: t0, lidClosed: false)
        return engine
    }

    private var armed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }

    /// § Settings: default on, so a mode an app that predates the guard arms has it.
    func testTheGuardIsOnUntilItIsTurnedOff() {
        XCTAssertTrue(KeepAwakeEngine().thermalGuard)
        XCTAssertTrue(engineArmed().thermalGuard)
    }

    /// A helper kept alive within its idle minute must not carry a guard an earlier mode turned
    /// off into the next one: every accepted Apply turns it back on.
    func testEveryApplyTurnsTheGuardBackOn() {
        var engine = engineArmed()
        _ = engine.setThermalGuard(enabled: false, now: t0 + 60, lidClosed: false)
        _ = engine.disarm(now: t0 + 120, lidClosed: false)
        XCTAssertFalse(engine.thermalGuard)
        _ = engine.arm(duration: 7_200, floorEnabled: true, now: t0 + 180, lidClosed: false)
        XCTAssertTrue(engine.thermalGuard, "a new mode starts with the guard on")
        _ = engine.setThermalGuard(enabled: false, now: t0 + 240, lidClosed: false)
        _ = engine.arm(duration: 7_200, floorEnabled: true, now: t0 + 300, lidClosed: false)
        XCTAssertTrue(engine.thermalGuard, "Apply while armed turns it on too")
        _ = engine.setThermalGuard(enabled: false, now: t0 + 360, lidClosed: false)
        _ = engine.arm(duration: 30, floorEnabled: true, now: t0 + 420, lidClosed: false)
        XCTAssertFalse(engine.thermalGuard, "a refused duration changes nothing")
    }

    func testCriticalWithTheLidClosedEndsTheModeAtThatReadingAndSleeps() {
        var engine = engineArmed()
        XCTAssertEqual(
            engine.thermal(level: .critical, now: t0 + 600, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 + 600, reason: .overheated), failure: nil)
        )
    }

    func testSeriousOnTwoReadingsAMinuteApartEndsTheMode() {
        var engine = engineArmed()
        XCTAssertEqual(
            engine.thermal(level: .serious, now: t0 + 600, lidClosed: true),
            Out(sleepDisabled: true, sleepNow: false, state: armed, failure: nil)
        )
        XCTAssertEqual(
            engine.thermal(level: .serious, now: t0 + 660, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 + 660, reason: .overheated), failure: nil)
        )
    }

    func testOneHotReadingThatCoolsWithinTheMinuteEndsNothing() {
        var engine = engineArmed()
        _ = engine.thermal(level: .serious, now: t0 + 600, lidClosed: true)
        _ = engine.thermal(level: .fair, now: t0 + 630, lidClosed: true)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 660, lidClosed: true).state, armed)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 719, lidClosed: true).state, armed)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 720, lidClosed: true).state, .ended(at: t0 + 720, reason: .overheated))
    }

    /// "With the lid open the guard ends nothing", and an open lid's heat does not count toward
    /// the minute.
    func testWithTheLidOpenHeatEndsNothingAndCountsNothing() {
        var engine = engineArmed()
        XCTAssertEqual(
            engine.thermal(level: .critical, now: t0 + 600, lidClosed: false),
            Out(sleepDisabled: true, sleepNow: false, state: armed, failure: nil)
        )
        _ = engine.thermal(level: .serious, now: t0 + 660, lidClosed: false)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 720, lidClosed: true).state, armed, "the run starts with the lid closed")
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 780, lidClosed: true).state, .ended(at: t0 + 780, reason: .overheated))
    }

    func testWithTheGuardOffHeatEndsNothing() {
        var engine = engineArmed()
        XCTAssertEqual(
            engine.setThermalGuard(enabled: false, now: t0 + 60, lidClosed: true),
            Out(sleepDisabled: true, sleepNow: false, state: armed, failure: nil)
        )
        XCTAssertFalse(engine.thermalGuard)
        XCTAssertEqual(engine.thermal(level: .critical, now: t0 + 600, lidClosed: true).state, armed)
    }

    /// Turning the guard on ends nothing by itself: the next reading decides, and its run starts
    /// there.
    func testTurningTheGuardOffForgetsTheHotRun() {
        var engine = engineArmed()
        _ = engine.thermal(level: .serious, now: t0 + 600, lidClosed: true)
        _ = engine.setThermalGuard(enabled: false, now: t0 + 630, lidClosed: true)
        XCTAssertEqual(engine.setThermalGuard(enabled: true, now: t0 + 640, lidClosed: true).state, armed)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 660, lidClosed: true).state, armed, "the run starts again at 660")
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 720, lidClosed: true).state, .ended(at: t0 + 720, reason: .overheated))
    }

    /// A mode past its deadline ends for the deadline, at the deadline, whatever the heat.
    func testAHotReadingAfterTheDeadlineEndsTheModeForTheDeadline() {
        var engine = engineArmed(for: 120)
        XCTAssertEqual(
            engine.thermal(level: .critical, now: t0 + 150, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: true, state: .ended(at: t0 + 120, reason: .deadline), failure: nil)
        )
    }

    func testAHotReadingWhileIdleOrEndedChangesNothing() {
        var idle = KeepAwakeEngine()
        XCTAssertEqual(
            idle.thermal(level: .critical, now: t0, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: false, state: .idle, failure: nil)
        )
        var ended = engineArmed()
        _ = ended.disarm(now: t0 + 60, lidClosed: false)
        XCTAssertEqual(
            ended.thermal(level: .critical, now: t0 + 120, lidClosed: true),
            Out(sleepDisabled: false, sleepNow: false, state: .ended(at: t0 + 60, reason: .cancelled), failure: nil)
        )
    }

    /// Apply after an end starts a new mode, whose minute starts at its own first hot reading.
    func testANewModeStartsWithoutTheLastModesHotRun() {
        var engine = engineArmed()
        _ = engine.thermal(level: .serious, now: t0 + 600, lidClosed: true)
        _ = engine.disarm(now: t0 + 610, lidClosed: true)
        _ = engine.arm(duration: 7_200, floorEnabled: true, now: t0 + 700, lidClosed: false)
        XCTAssertEqual(
            engine.thermal(level: .serious, now: t0 + 700, lidClosed: true).state,
            .armed(deadline: t0 + 7_900, floorEnabled: true)
        )
    }

    /// Apply while armed replaces the deadline and keeps the minute already counting.
    func testApplyWhileArmedKeepsTheHotRun() {
        var engine = engineArmed()
        _ = engine.thermal(level: .serious, now: t0 + 600, lidClosed: true)
        _ = engine.arm(duration: 7_200, floorEnabled: true, now: t0 + 630, lidClosed: false)
        XCTAssertEqual(engine.thermal(level: .serious, now: t0 + 660, lidClosed: true).state, .ended(at: t0 + 660, reason: .overheated))
    }

    /// While a run counts, the next tick comes when its minute is up, even when a later input
    /// would put the minute tick after it.
    func testWhileTheHeatHoldsTheNextTickComesWhenTheMinuteIsUp() {
        var engine = engineArmed(for: 3_600)
        XCTAssertEqual(engine.nextTick(now: t0 + 50), t0 + 110)
        _ = engine.thermal(level: .serious, now: t0 + 30, lidClosed: true)
        XCTAssertEqual(engine.nextTick(now: t0 + 50), t0 + 90)
        _ = engine.thermal(level: .fair, now: t0 + 60, lidClosed: true)
        XCTAssertEqual(engine.nextTick(now: t0 + 60), t0 + 120)
    }
}
