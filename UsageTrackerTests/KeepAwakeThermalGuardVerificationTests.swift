import XCTest
import ServiceManagement
import SwiftUI
@testable import Omelette

// Verification of the keep-awake thermal guard, written from the spec
// (docs/superpowers/specs/2026-11-19-keep-awake-thermal-guard.md), not from the coder's tests.
//
// Coverage map: the rule end to end through the service, § Rule and § Plan decisions accepted
// by the session items 1 to 3 (`KeepAwakeThermalGuardRuleThroughTheServiceTests`); item 2a,
// the pending tick (`KeepAwakeThermalGuardPendingTickVerificationTests`); the wire and the
// state file across versions, § Daemon and item 4 (`KeepAwakeThermalGuardWireVerificationTests`);
// the app's reconciliation against the real service, items 5, 6 and 12
// (`KeepAwakeThermalGuardLoopVerificationTests`); the setting's default (§ Settings).

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let closedLid = KeepAwakeLid(closed: true, causesSleep: true)

/// A temp directory per test, as every keep-awake suite has one.
private func makeDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - The rule end to end through the service

/// Spec § Rule and § Plan decisions accepted by the session, items 1 to 3: the minute is counted
/// from the first reading with the lid closed, a cooler or lid-open reading breaks the run, the
/// battery floor and the deadline win over heat at one reading, and an end for heat takes the
/// same path as any other end (flag cleared and read back, then `pmset sleepnow`, a failed clear
/// retried), also after a daemon restart.
final class KeepAwakeThermalGuardRuleThroughTheServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory("KeepAwakeThermalGuardRuleThroughTheServiceTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func stateFile(_ name: String = "keepawake.json") -> KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent(name))
    }

    private func armed(_ fake: FakeKeepAwakeMachine, seconds: TimeInterval = 7_200, floor: Bool = true, file: String = "keepawake.json") async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile(file))
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: seconds, floorEnabled: floor, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    private var stillArmed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }
    private let endCalls = ["set 0", "read", "sleepnow"]

    // MARK: the minute

    /// "`serious` must hold for 60 s or more from the run's first reading": 59 s ends nothing, 60 s ends.
    func testSeriousHeldFiftyNineSecondsEndsNothingAndHeldSixtyEndsTheMode() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 10)
        let at59 = await service.thermalChanged(now: t0 + 69)
        XCTAssertEqual(at59.state, stillArmed)
        XCTAssertEqual(fake.with { $0.calls }, [], "59 s of heat runs no pmset")
        let at60 = await service.thermalChanged(now: t0 + 70)
        XCTAssertEqual(at60.state, .ended(at: t0 + 70, reason: .overheated))
        XCTAssertEqual(fake.with { $0.calls }, endCalls)
    }

    /// "One hot reading that cools within the minute ends nothing", and a later rise is a new minute.
    func testALevelThatFallsBackToFairInsideTheMinuteEndsNothingAndALaterRiseStartsANewMinute() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 10)              // first hot reading
        fake.with { $0.thermal = .fair }
        _ = await service.thermalChanged(now: t0 + 40)              // cooled: the run is gone
        fake.with { $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 50)              // the new run begins here
        // The pending tick (the Apply's, t0 + 60) reads serious; the minute it brings is the new one.
        let tick = await service.tick(now: t0 + 60)
        XCTAssertEqual(tick.state, stillArmed, "10 s into the new run, 50 s after the first reading")
        XCTAssertEqual(fake.with { $0.scheduled.last ?? nil }, t0 + 110, "the new minute's end, not a minute after the tick")
        let before = await service.thermalChanged(now: t0 + 109)
        XCTAssertEqual(before.state, stillArmed, "59 s into the new run, 99 s after the first reading")
        XCTAssertEqual(fake.with { $0.calls }, [])
        let reply = await service.thermalChanged(now: t0 + 110)
        XCTAssertEqual(reply.state, .ended(at: t0 + 110, reason: .overheated))
        XCTAssertEqual(fake.with { $0.calls }, endCalls)
    }

    /// "Only readings taken with the lid closed count": a reading with the lid open between two
    /// closed ones breaks the run, even when the level never fell.
    func testALidOpenedBetweenTwoHotReadingsStartsTheMinuteAgain() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.thermal = .serious; $0.lid = closedLid }
        _ = await service.thermalChanged(now: t0 + 5)
        fake.with { $0.lid = KeepAwakeLid(closed: false, causesSleep: true) }
        _ = await service.thermalChanged(now: t0 + 35)
        fake.with { $0.lid = closedLid }
        let reopened = await service.thermalChanged(now: t0 + 75)    // 70 s after the first, 0 s into the new run
        XCTAssertEqual(reopened.state, stillArmed)
        let almost = await service.thermalChanged(now: t0 + 134)
        XCTAssertEqual(almost.state, stillArmed)
        let reply = await service.thermalChanged(now: t0 + 135)
        XCTAssertEqual(reply.state, .ended(at: t0 + 135, reason: .overheated))
    }

    /// "Heat with the lid open then closed counts from the first closed-lid reading", over a long open spell.
    func testHeatWithTheLidOpenForAnHourThenClosedCountsFromTheFirstClosedReading() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.thermal = .serious }
        for minute in 1...60 {
            let reply = await service.tick(now: t0 + Double(minute) * 60)
            XCTAssertEqual(reply.state, stillArmed, "minute \(minute): an open Mac under load is ordinary use")
        }
        XCTAssertEqual(fake.with { $0.calls }, [])
        fake.with { $0.lid = closedLid }
        let first = await service.tick(now: t0 + 3_660)
        XCTAssertEqual(first.state, stillArmed, "the first closed-lid reading is the start of the minute")
        let second = await service.tick(now: t0 + 3_720)
        XCTAssertEqual(second.state, .ended(at: t0 + 3_720, reason: .overheated))
    }

    /// "The guard off never ends, and off-then-on starts the minute afresh", through the XPC entry point.
    func testWithTheGuardOffCriticalNeverEndsAndTurnedOnItIsTheNextReadingThatDecides() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .critical }
        let off = await service.setThermalGuard(enabled: false, now: t0 + 5)
        XCTAssertEqual(off.thermalGuard, false)
        for second in stride(from: 60, through: 1_200, by: 60) {
            let reply = await service.tick(now: t0 + Double(second))
            XCTAssertEqual(reply.state, stillArmed, "guard off, critical, lid closed, \(second) s in")
        }
        XCTAssertEqual(fake.with { $0.calls }, [])
        let on = await service.setThermalGuard(enabled: true, now: t0 + 1_230)
        XCTAssertEqual(on.state, stillArmed, "turning it on reads no level")
        XCTAssertEqual(fake.with { $0.calls }, [])
        let reading = await service.thermalChanged(now: t0 + 1_240)
        XCTAssertEqual(reading.state, .ended(at: t0 + 1_240, reason: .overheated), "critical ends at the first reading after")
    }

    func testTurnedOffAndOnAgainSeriousStartsItsMinuteAtTheNextReadingNotBefore() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 10)
        _ = await service.setThermalGuard(enabled: false, now: t0 + 20)
        let whileOff = await service.thermalChanged(now: t0 + 200)
        XCTAssertEqual(whileOff.state, stillArmed)
        _ = await service.setThermalGuard(enabled: true, now: t0 + 210)
        let first = await service.thermalChanged(now: t0 + 220)
        XCTAssertEqual(first.state, stillArmed, "190 s after the first reading of the old run, 0 s into the new one")
        let last = await service.thermalChanged(now: t0 + 279)
        XCTAssertEqual(last.state, stillArmed)
        let reply = await service.thermalChanged(now: t0 + 280)
        XCTAssertEqual(reply.state, .ended(at: t0 + 280, reason: .overheated))
    }

    /// "Closed but not causing sleep" is an external display in use: nothing ends, however long.
    func testClamshellOnAnExternalDisplayNeverEndsForHeatHoweverLong() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: false); $0.thermal = .critical }
        for minute in 1...30 {
            let reply = await service.tick(now: t0 + Double(minute) * 60)
            XCTAssertEqual(reply.state, stillArmed)
        }
        let notified = await service.thermalChanged(now: t0 + 1_850)
        XCTAssertEqual(notified.state, stillArmed)
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    // MARK: who wins at one reading

    func testTheDeadlineWinsOverHeatAtOneReading() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake, seconds: 120)
        fake.with { $0.lid = closedLid; $0.thermal = .critical; $0.power = KeepAwakePower(onBattery: true, percent: 5) }
        let reply = await service.tick(now: t0 + 180)
        XCTAssertEqual(reply.state, .ended(at: t0 + 120, reason: .deadline))
        XCTAssertEqual(fake.with { $0.calls }, endCalls)
        XCTAssertEqual(stateFile().load(), .ended(at: t0 + 120, reason: .deadline))
    }

    func testTheBatteryFloorWinsOverHeatAtOneReading() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .critical; $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .batteryFloor))
        XCTAssertEqual(fake.with { $0.calls }, endCalls, "one end: one clear, one sleep")
        XCTAssertEqual(stateFile().load(), .ended(at: t0 + 60, reason: .batteryFloor))
    }

    func testWithTheFloorSwitchedOffALowBatteryDoesNotHideHeat() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake, floor: false)
        fake.with { $0.lid = closedLid; $0.thermal = .critical; $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .overheated))
        XCTAssertEqual(fake.with { $0.calls }, endCalls)
    }

    /// The poll (the app's `state`) is a reading with the same order as a tick's.
    func testTheAppsPollEndsForHeatLikeATickAndFloorStillComesFirst() async {
        let low = FakeKeepAwakeMachine()
        let lowService = await armed(low)
        low.with { $0.lid = closedLid; $0.thermal = .critical; $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        let floor = await lowService.state(now: t0 + 30)
        XCTAssertEqual(floor.state, .ended(at: t0 + 30, reason: .batteryFloor))
        let hotFake = FakeKeepAwakeMachine()
        let hotService = await armed(hotFake, file: "hot.json")
        hotFake.with { $0.lid = closedLid; $0.thermal = .critical; $0.power = KeepAwakePower(onBattery: false, percent: 100) }
        let hot = await hotService.state(now: t0 + 30)
        XCTAssertEqual(hot.state, .ended(at: t0 + 30, reason: .overheated))
        XCTAssertEqual(hotFake.with { $0.calls }, endCalls)
    }

    // MARK: the end path

    /// What an end looks like to the machine and to the file: the calls, a failure's retry, what the
    /// file owes, and what a restarted daemon does with it. Times are relative to the end.
    private struct EndTrace: Equatable {
        var firstCalls: [String] = []
        var firstFailure: KeepAwakeFailure?
        var firstNextTick: TimeInterval?
        var owedSleep = false
        var ownsFlag = false
        var retryCalls: [String] = []
        var retryFailure: KeepAwakeFailure?
        var retryNextTick: TimeInterval?
        var owedSleepAfter = false
        var ownsFlagAfter = false
        var restartCalls: [String] = []
        var restartedState: KeepAwakeState?
        var restartOwesSleep = false
    }

    /// Ends a mode for `reason` (heat or the deadline), the clear failing the first time, and
    /// records what happened; the daemon then restarts on the same file.
    private func trace(_ reason: KeepAwakeEndReason, failFirstClear: Bool, name: String) async -> (EndTrace, KeepAwakeState?) {
        let fake = FakeKeepAwakeMachine()
        let file = stateFile(name)
        let service = KeepAwakeService(machine: fake.machine(), stateFile: file)
        _ = await service.start(now: t0)
        let duration: TimeInterval = reason == .deadline ? 120 : 7_200
        _ = await service.arm(seconds: duration, floorEnabled: true, now: t0)
        let endMoment = reason == .deadline ? t0 + 120 : t0 + 60
        fake.with {
            $0.lid = closedLid
            $0.thermal = reason == .overheated ? .critical : .nominal
            $0.calls = []; $0.scheduled = []
            if failFirstClear { $0.failSetsRemaining = 1 }
        }
        var t = EndTrace()
        let first = await service.tick(now: endMoment)
        t.firstCalls = fake.with { $0.calls }
        t.firstFailure = first.failure
        t.firstNextTick = (fake.with { $0.scheduled.last ?? nil }).map { $0.timeIntervalSince(endMoment) }
        t.owedSleep = file.loadSleepOwed()
        t.ownsFlag = file.loadOwnsFlag()
        fake.with { $0.calls = []; $0.scheduled = [] }
        let retry = await service.tick(now: endMoment + 60)
        t.retryCalls = fake.with { $0.calls }
        t.retryFailure = retry.failure
        t.retryNextTick = (fake.with { $0.scheduled.last ?? nil }).map { $0.timeIntervalSince(endMoment) }
        t.owedSleepAfter = file.loadSleepOwed()
        t.ownsFlagAfter = file.loadOwnsFlag()
        return (t, file.load())
    }

    /// "Ending follows the existing path": heat and the deadline leave the same calls, the same
    /// retry, the same file flags, whether the clear takes at once or fails once.
    func testAnEndForHeatMakesTheSameCallsAsAnEndForTheDeadlineWhenTheClearTakes() async {
        let (heat, heatFile) = await trace(.overheated, failFirstClear: false, name: "a.json")
        let (deadline, deadlineFile) = await trace(.deadline, failFirstClear: false, name: "b.json")
        XCTAssertEqual(heat.firstCalls, endCalls)
        XCTAssertEqual(heat, deadline)
        XCTAssertEqual(heatFile, .ended(at: t0 + 60, reason: .overheated))
        XCTAssertEqual(deadlineFile, .ended(at: t0 + 120, reason: .deadline))
    }

    func testAFailedClearAfterAnEndForHeatIsRetriedAndOwedSleepPaidAsForTheDeadline() async {
        let (heat, _) = await trace(.overheated, failFirstClear: true, name: "a.json")
        let (deadline, _) = await trace(.deadline, failFirstClear: true, name: "b.json")
        XCTAssertEqual(heat.firstCalls, ["set 0"], "pmset exited non-zero: no read, no sleep yet")
        XCTAssertEqual(heat.firstFailure, .commandFailed(command: "pmset", status: 1))
        XCTAssertEqual(heat.firstNextTick, 60, "the retry is a minute on")
        XCTAssertTrue(heat.owedSleep)
        XCTAssertTrue(heat.ownsFlag)
        XCTAssertEqual(heat.retryCalls, endCalls, "the retry clears, reads back, then sleeps")
        XCTAssertFalse(heat.owedSleepAfter)
        XCTAssertFalse(heat.ownsFlagAfter)
        XCTAssertEqual(heat, deadline)
    }

    /// An end for heat whose clear failed, then the daemon restarts: the file says overheated,
    /// the helper's claim on the flag and the sleep it owes; the start pays both and keeps the reason.
    func testADaemonRestartedAfterAnEndForHeatWithAFailedClearPaysTheSleepAndKeepsTheReason() async throws {
        let fake = FakeKeepAwakeMachine()
        let file = stateFile("heat.json")
        let service = KeepAwakeService(machine: fake.machine(), stateFile: file)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.lid = closedLid; $0.thermal = .critical; $0.failSetsRemaining = 1; $0.calls = [] }
        _ = await service.tick(now: t0 + 60)
        XCTAssertEqual(file.load(), .ended(at: t0 + 60, reason: .overheated))
        XCTAssertTrue(file.loadOwnsFlag())
        XCTAssertTrue(file.loadSleepOwed())
        XCTAssertEqual(fake.with { $0.flag }, .set)
        // launchd starts a new daemon on the same file.
        fake.with { $0.calls = [] }
        let restarted = KeepAwakeService(machine: fake.machine(), stateFile: file)
        let reply = await restarted.start(now: t0 + 90)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .overheated), "the end keeps its reason and its time")
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
        XCTAssertEqual(file.load(), .ended(at: t0 + 60, reason: .overheated))
    }

    /// After an end, nothing from the old hot run is left: a new Apply is a new mode and a new minute.
    func testANewApplyAfterAnEndForHeatStartsCleanAndNothingIsPending() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 10)
        let ended = await service.thermalChanged(now: t0 + 70)
        XCTAssertEqual(ended.state, .ended(at: t0 + 70, reason: .overheated))
        XCTAssertEqual(fake.with { $0.scheduled.last }, Optional<Date?>.some(nil), "the end cancelled the tick: nothing pending")
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 500)
        XCTAssertEqual(fake.with { $0.scheduled.last ?? nil }, t0 + 560, "a fresh tick a minute after the Apply")
        let first = await service.thermalChanged(now: t0 + 510)
        XCTAssertEqual(first.state, .armed(deadline: t0 + 7_700, floorEnabled: true), "the old run's first reading (t0 + 10) is not carried over")
        XCTAssertEqual(first.thermalGuard, true)
    }

    /// A helper whose guard was switched off ends nothing, then the next Apply turns it on again.
    func testEveryApplyTurnsAGuardThatWasSwitchedOffBackOnForTheNewMode() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = closedLid; $0.thermal = .critical }
        _ = await service.setThermalGuard(enabled: false, now: t0 + 5)
        _ = await service.disarm(now: t0 + 10)
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 20)
        XCTAssertEqual(reply.thermalGuard, true, "an Apply turns the guard on, whatever the last mode left")
        let tick = await service.tick(now: t0 + 80)
        XCTAssertEqual(tick.state, .ended(at: t0 + 80, reason: .overheated))
    }
}

// MARK: - Item 2a: the pending tick

/// Spec § Plan decisions accepted by the session, item 2a: "The helper never moves a pending
/// reading later … The tick the helper schedules is the earlier of the pending one and the one the
/// input calls for; the bounds of item 2 hold whatever arrives in between." Mixed inputs at
/// irregular intervals, seeded, with the lid closing at a random moment.
final class KeepAwakeThermalGuardPendingTickVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory("KeepAwakeThermalGuardPendingTickVerificationTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
    }

    private struct Outcome {
        var ended: KeepAwakeState?
        var lidClosedAt: Date
        var violations: [String]
        var events: Int
    }

    /// Runs the helper's clock: inputs that take no reading (a power notification, the floor's
    /// switch, the guard's switch, a re-arm) and the app's poll (which does), at irregular gaps and
    /// sometimes exactly at the pending tick, and the tick whenever the time the machine was last
    /// asked for comes before the next input. The lid closes at a random moment on a Mac that is
    /// already at `level`.
    private func simulate(seed: UInt64, level: KeepAwakeThermalLevel) async -> Outcome {
        var rng = SplitMix(state: seed)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 80); $0.thermal = level }
        let file = KeepAwakeStateFile(url: directory.appendingPathComponent("sim-\(seed)-\(level.rawValue).json"))
        let service = KeepAwakeService(machine: fake.machine(), stateFile: file)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 86_400, floorEnabled: true, now: t0)
        let lidCloses = t0 + Double(rng.int(20...300))
        var lidClosedNow = false
        var violations: [String] = []
        var events = 0
        var ended: KeepAwakeState?
        func scheduledNow() -> Date? { fake.with { $0.scheduled.last ?? nil } }
        func closeLidIfDue(_ time: Date) {
            if !lidClosedNow, time >= lidCloses {
                lidClosedNow = true
                fake.with { $0.lid = closedLid }
            }
        }
        var pending = scheduledNow()
        var now = t0
        let horizon = lidCloses + 200
        outer: while now < horizon, events < 5_000 {
            var inputTime = now + Double(rng.int(1...45))
            if let p = pending, p > now, rng.int(0...5) == 0 { inputTime = p }   // an input exactly at the pending tick
            while let p = pending, p < inputTime {
                closeLidIfDue(p)
                let reply = await service.tick(now: p)
                events += 1
                now = p
                pending = scheduledNow()
                if !reply.state.isArmed { ended = reply.state; break outer }
            }
            closeLidIfDue(inputTime)
            let before = pending
            let reply: KeepAwakeReply
            switch rng.int(0...4) {
            case 0: reply = await service.powerChanged(now: inputTime)
            case 1: reply = await service.setFloor(enabled: true, now: inputTime)
            case 2: reply = await service.setThermalGuard(enabled: true, now: inputTime)
            case 3: reply = await service.arm(seconds: 86_400, floorEnabled: true, now: inputTime)
            default: reply = await service.state(now: inputTime)
            }
            events += 1
            now = inputTime
            pending = scheduledNow()
            if reply.state.isArmed, let before {
                if let pending {
                    if pending > before { violations.append("seed \(seed): pending moved from \(before.timeIntervalSince(t0)) to \(pending.timeIntervalSince(t0)) at \(inputTime.timeIntervalSince(t0))") }
                } else {
                    violations.append("seed \(seed): pending tick dropped while armed at \(inputTime.timeIntervalSince(t0))")
                }
            }
            if !reply.state.isArmed { ended = reply.state; break }
        }
        return Outcome(ended: ended, lidClosedAt: lidCloses, violations: violations, events: events)
    }

    private func check(_ level: KeepAwakeThermalLevel, bound: TimeInterval, seeds: ClosedRange<UInt64>) async {
        var totalEvents = 0
        defer { XCTAssertGreaterThan(totalEvents, seeds.count * 8, "the simulation really ran: inputs and ticks delivered") }
        for seed in seeds {
            let outcome = await simulate(seed: seed, level: level)
            totalEvents += outcome.events
            XCTAssertEqual(outcome.violations, [], "seed \(seed), \(level)")
            guard case .ended(let at, let reason)? = outcome.ended else {
                XCTFail("seed \(seed), \(level): still armed \(outcome.lidClosedAt.timeIntervalSince(t0)) s + 200 s later (\(outcome.events) events)")
                continue
            }
            XCTAssertEqual(reason, .overheated, "seed \(seed), \(level)")
            XCTAssertGreaterThanOrEqual(at, outcome.lidClosedAt, "seed \(seed), \(level): ended before the lid closed")
            XCTAssertLessThanOrEqual(
                at.timeIntervalSince(outcome.lidClosedAt), bound,
                "seed \(seed), \(level): ended \(at.timeIntervalSince(outcome.lidClosedAt)) s after the lid closed"
            )
        }
    }

    /// `critical` ends the mode at the first closed-lid reading, at most a minute after the lid closes.
    func testNoMixOfInputsPostponesACriticalEndPastAMinuteAfterTheLidCloses() async {
        await check(.critical, bound: 60, seeds: 1...80)
    }

    /// `serious` ends it at most two minutes after the lid closes.
    func testNoMixOfInputsPostponesASeriousEndPastTwoMinutesAfterTheLidCloses() async {
        await check(.serious, bound: 120, seeds: 1...80)
    }

    /// With the lid open, ten minutes of the same mixed inputs on a critical Mac end nothing.
    func testTheSameMixOnACriticalMacWithTheLidOpenEndsNothing() async {
        var rng = SplitMix(state: 99)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 80); $0.thermal = .critical }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("open.json")))
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 86_400, floorEnabled: true, now: t0)
        fake.with { $0.calls = [] }
        var pending: Date? = fake.with { $0.scheduled.last ?? nil }
        var now = t0
        while now < t0 + 600 {
            let inputTime = now + Double(rng.int(1...45))
            while let p = pending, p < inputTime {
                let reply = await service.tick(now: p)
                XCTAssertTrue(reply.state.isArmed)
                now = p
                pending = fake.with { $0.scheduled.last ?? nil }
            }
            let reply = rng.int(0...1) == 0 ? await service.powerChanged(now: inputTime) : await service.state(now: inputTime)
            XCTAssertTrue(reply.state.isArmed)
            now = inputTime
            pending = fake.with { $0.scheduled.last ?? nil }
        }
        XCTAssertEqual(fake.with { $0.calls }, [], "no clear and no sleep after the Apply's own calls")
    }

    /// An input arriving exactly at the pending time leaves the tick at that time, and the tick still comes.
    func testAnInputExactlyAtThePendingTickDoesNotMoveItAndTheTickStillReads() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 80); $0.thermal = .critical }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("exact.json")))
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 86_400, floorEnabled: true, now: t0)
        fake.with { $0.lid = closedLid; $0.scheduled = [] }
        let notification = await service.powerChanged(now: t0 + 60)
        XCTAssertTrue(notification.state.isArmed, "a power notification is no thermal reading")
        XCTAssertEqual(fake.with { $0.scheduled.last ?? nil }, t0 + 60, "not t0 + 120")
        let tick = await service.tick(now: t0 + 60)
        XCTAssertEqual(tick.state, .ended(at: t0 + 60, reason: .overheated))
    }

    /// A wall clock stepped forward (a manual change, an NTP jump) leaves the overdue tick where it was;
    /// the tick that then fires reads, and a hot run is counted by the clock it is read with.
    func testAClockSteppedForwardLeavesTheOverdueTickAndTheNextReadingDecides() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 80); $0.thermal = .serious }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("step.json")))
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 86_400, floorEnabled: true, now: t0)
        fake.with { $0.lid = closedLid; $0.scheduled = [] }
        _ = await service.thermalChanged(now: t0 + 10)                    // the run begins
        let stepped = await service.powerChanged(now: t0 + 3_600)         // the clock jumped an hour
        XCTAssertTrue(stepped.state.isArmed)
        XCTAssertEqual(fake.with { $0.scheduled.last ?? nil }, t0 + 60, "overdue, kept: the timer fires it at once")
        let tick = await service.tick(now: t0 + 3_600)
        XCTAssertEqual(tick.state, .ended(at: t0 + 3_600, reason: .overheated))
    }

    /// A clock set back below the run's start restarts the run rather than stretching it.
    func testAClockSetBackStartsTheHotRunAgain() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.thermal = .serious; $0.lid = closedLid }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("back.json")))
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 86_400, floorEnabled: true, now: t0)
        _ = await service.thermalChanged(now: t0 + 1_000)
        let back = await service.thermalChanged(now: t0 + 500)            // the clock went back 500 s
        XCTAssertTrue(back.state.isArmed)
        let before = await service.thermalChanged(now: t0 + 559)
        XCTAssertTrue(before.state.isArmed, "59 s into the run that began at the set-back reading")
        let at = await service.thermalChanged(now: t0 + 560)
        XCTAssertEqual(at.state, .ended(at: t0 + 560, reason: .overheated))
    }
}

// MARK: - The wire and the state file across versions

/// Spec § Daemon ("The state file and the XPC answer stay readable across an update in both
/// directions") and § Plan decisions accepted by the session item 4 and § Accepted risks (an
/// `ended` state decodes whenever its time does). 4.3.0's shapes are `KeepAwakeLegacy`, which
/// the coder copied from `2fa398b`; here they are also written out as literal bytes.
final class KeepAwakeThermalGuardWireVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory("KeepAwakeThermalGuardWireVerificationTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private func legacyEncode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    private func legacyDecode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func legacy(_ state: KeepAwakeState) -> KeepAwakeLegacy.State {
        switch state {
        case .idle: return .idle
        case .armed(let deadline, let floor): return .armed(deadline: deadline, floorEnabled: floor)
        case .ended(let at, let reason):
            return .ended(at: at, reason: KeepAwakeLegacy.EndReason(rawValue: reason.olderBuildsRead.rawValue)!)
        }
    }

    private var allStates: [KeepAwakeState] {
        [.idle, .armed(deadline: t0 + 7_200, floorEnabled: true), .armed(deadline: t0 + 90.5, floorEnabled: false)]
            + KeepAwakeEndReason.allCases.map { .ended(at: t0 + 33.25, reason: $0) }
    }

    private var allFailures: [KeepAwakeFailure?] {
        [nil, .invalidDuration, .commandFailed(command: "pmset", status: 1), .readBack(expected: true), .readBack(expected: false), .flagStillSet]
    }

    // MARK: bytes 4.3.0 wrote and reads

    /// "The bytes of every state 4.3.0 could write": for the five reasons 4.3.0 knows, a reply and a
    /// file written by this build are byte for byte what 4.3.0's synthesized coding writes.
    func testEveryStateAndReplyFourThreeZeroCouldWriteIsWrittenByteForByteTheSame() throws {
        for state in allStates {
            if case .ended(_, let reason) = state, reason == .overheated { continue }
            for failure in allFailures {
                let reply = KeepAwakeReply(state: state, failure: failure)
                XCTAssertEqual(
                    String(decoding: KeepAwakeCoding.encode(reply), as: UTF8.self),
                    String(decoding: legacyEncode(KeepAwakeLegacy.Reply(state: legacy(state), failure: failure)), as: UTF8.self),
                    "\(state) \(String(describing: failure))"
                )
                for (owed, owns) in [(false, false), (true, false), (false, true), (true, true)] {
                    try stateFile.save(state, failure: failure, sleepOwed: owed, ownsFlag: owns)
                    let written = try Data(contentsOf: stateFile.url)
                    let envelope = KeepAwakeLegacy.Envelope(
                        version: 1, state: legacy(state), failure: failure,
                        sleepOwed: owed ? true : nil, ownsFlag: owns ? true : nil
                    )
                    XCTAssertEqual(String(decoding: written, as: UTF8.self), String(decoding: legacyEncode(envelope), as: UTF8.self))
                }
            }
        }
    }

    /// 4.3.0's own bytes, of every shape, read by this build as what they say.
    func testThisBuildReadsEveryShapeFourThreeZeroWroteAsWhatItSays() throws {
        for state in allStates {
            if case .ended(_, let reason) = state, reason == .overheated { continue }
            for failure in allFailures {
                let bytes = legacyEncode(KeepAwakeLegacy.Reply(state: legacy(state), failure: failure))
                let decoded = KeepAwakeCoding.decode(KeepAwakeReply.self, from: bytes)
                XCTAssertEqual(decoded, KeepAwakeReply(state: state, failure: failure))
                XCTAssertNil(decoded?.thermal)
                XCTAssertNil(decoded?.thermalGuard, "no field: a helper that predates the guard")
            }
            let file = legacyEncode(KeepAwakeLegacy.Envelope(version: 1, state: legacy(state), failure: .flagStillSet, sleepOwed: true, ownsFlag: true))
            try file.write(to: stateFile.url)
            XCTAssertEqual(stateFile.load(), state)
            XCTAssertEqual(stateFile.loadFailure(), .flagStillSet)
            XCTAssertTrue(stateFile.loadSleepOwed())
            XCTAssertTrue(stateFile.loadOwnsFlag())
        }
    }

    /// An end for heat, in the reply and in the file, is an end that 4.3.0 reads, with the sleep and
    /// the flag the helper still owes beside it.
    func testFourThreeZeroReadsAnEndForHeatAsAStoppedHelperAndKeepsTheFlagAndTheSleep() throws {
        let overheated = KeepAwakeState.ended(at: t0 + 60, reason: .overheated)
        let reply = KeepAwakeReply(state: overheated, failure: nil, thermal: .critical, thermalGuard: false)
        XCTAssertEqual(
            legacyDecode(KeepAwakeLegacy.Reply.self, KeepAwakeCoding.encode(reply)),
            KeepAwakeLegacy.Reply(state: .ended(at: t0 + 60, reason: .stopped), failure: nil)
        )
        try stateFile.save(overheated, failure: .readBack(expected: false), sleepOwed: true, ownsFlag: true)
        let file = try XCTUnwrap(legacyDecode(KeepAwakeLegacy.Envelope.self, Data(contentsOf: stateFile.url)))
        XCTAssertEqual(file, KeepAwakeLegacy.Envelope(version: 1, state: .ended(at: t0 + 60, reason: .stopped), failure: .readBack(expected: false), sleepOwed: true, ownsFlag: true))
        XCTAssertEqual(stateFile.load(), overheated, "this build reads its own file back with the real reason")
    }

    // MARK: the limits of the tolerance

    /// A hand-written `ended` payload, as it might arrive from another build or a damaged file.
    private func ended(_ fields: String) -> String { #"{"ended":{\#(fields)}}"# }
    private let at = #""at":1793000000"#

    private var toleratedEnds: [(String, KeepAwakeEndReason)] {
        [
            (ended(at), .stopped),                                                              // no reason, no cause
            (ended(#"\#(at),"reason":null"#), .stopped),
            (ended(#"\#(at),"reason":7"#), .stopped),                                           // not a string
            (ended(#"\#(at),"reason":true"#), .stopped),
            (ended(#"\#(at),"reason":["deadline"]"#), .stopped),
            (ended(#"\#(at),"reason":{"x":1}"#), .stopped),
            (ended(#"\#(at),"reason":"melted""#), .stopped),                                    // unknown
            (ended(#"\#(at),"reason":"""#), .stopped),
            (ended(#"\#(at),"reason":"deadline""#), .deadline),                                 // 4.3.0's own
            (ended(#"\#(at),"reason":"stopped","cause":"overheated""#), .overheated),           // this build's
            (ended(#"\#(at),"cause":"overheated""#), .overheated),                              // cause alone
            (ended(#"\#(at),"reason":7,"cause":"overheated""#), .overheated),                   // cause beats a bad reason
            (ended(#"\#(at),"reason":"melted","cause":"overheated""#), .overheated),
            (ended(#"\#(at),"reason":"stopped","cause":"melted""#), .stopped),                  // a cause not known
            (ended(#"\#(at),"reason":"batteryFloor","cause":"melted""#), .batteryFloor),        // falls back to the reason
            (ended(#"\#(at),"reason":"restarted","cause":4"#), .restarted),
            (ended(#"\#(at),"reason":"cancelled","cause":null"#), .cancelled),
            (ended(#"\#(at),"reason":"cancelled","cause":["overheated"]"#), .cancelled),
            (ended(#"\#(at),"reason":"stopped","cause":"overheated","later":[1]"#), .overheated),
        ]
    }

    /// What does not read, as 4.3.0 did not read it: no time, a time that is not one, no `ended`
    /// payload, two states, a state no build knows, an `armed` with a field missing or mistyped.
    private var rejectedStates: [String] {
        [
            ended(#""reason":"stopped""#),
            ended(#""reason":"stopped","cause":"overheated""#),
            ended(#""at":"soon","reason":"stopped""#),
            ended(#""at":null,"reason":"deadline""#),
            ended(#""at":true,"reason":"deadline""#),
            ended(#""at":{"s":1},"reason":"deadline""#),
            ended(""),
            #"{"ended":5}"#,
            #"{"ended":null}"#,
            #"{"ended":[]}"#,
            #"{}"#,
            #"{"paused":{}}"#,
            #"{"idle":{},"ended":{"at":1793000000,"reason":"stopped"}}"#,
            #"{"armed":{"deadline":1793007200,"floorEnabled":true},"idle":{}}"#,
            #"{"ended":{"at":1793000000,"reason":"stopped"},"armed":{"deadline":1793007200,"floorEnabled":true}}"#,
            #"{"armed":{"deadline":1793007200}}"#,
            #"{"armed":{"floorEnabled":true}}"#,
            #"{"armed":{"deadline":1793007200,"floorEnabled":"yes"}}"#,
            #"{"armed":{"deadline":"later","floorEnabled":true}}"#,
        ]
    }

    func testAnEndedPayloadReadsWheneverItsTimeDoesAndMissingOrUnknownReasonsReadAsStopped() throws {
        for (json, expected) in toleratedEnds {
            XCTAssertEqual(
                KeepAwakeCoding.decode(KeepAwakeState.self, from: Data(json.utf8)),
                .ended(at: t0, reason: expected),
                json
            )
            // In a reply, with and without the new keys.
            XCTAssertEqual(
                KeepAwakeCoding.decode(KeepAwakeReply.self, from: Data(#"{"state":\#(json)}"#.utf8)),
                KeepAwakeReply(state: .ended(at: t0, reason: expected), failure: nil),
                json
            )
            XCTAssertEqual(
                KeepAwakeCoding.decode(KeepAwakeReply.self, from: Data(#"{"state":\#(json),"thermal":"fair","thermalGuard":true}"#.utf8)),
                KeepAwakeReply(state: .ended(at: t0, reason: expected), failure: nil, thermal: .fair, thermalGuard: true),
                json
            )
        }
    }

    /// "The file never loses the helper's claim on the flag over one field": the flag and the sleep
    /// owed beside every tolerated end survive, and so does the failure.
    func testTheFlagTheSleepAndTheFailureBesideAToleratedEndSurviveInTheFile() throws {
        for (json, expected) in toleratedEnds {
            try Data(#"{"failure":{"readBack":{"expected":false}},"ownsFlag":true,"sleepOwed":true,"state":\#(json),"version":1}"#.utf8).write(to: stateFile.url)
            XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: expected), json)
            XCTAssertTrue(stateFile.loadOwnsFlag(), json)
            XCTAssertTrue(stateFile.loadSleepOwed(), json)
            XCTAssertEqual(stateFile.loadFailure(), .readBack(expected: false), json)
        }
    }

    /// The tolerance is for the reason only: every state above still fails, in a bare state, in
    /// a reply and in the file (which then reads as nothing, as before), exactly as 4.3.0 did.
    func testTheToleranceStopsAtTheReasonEverythingElseStillFailsAsItDidBefore() throws {
        for json in rejectedStates {
            XCTAssertNil(KeepAwakeCoding.decode(KeepAwakeState.self, from: Data(json.utf8)), json)
            XCTAssertNil(KeepAwakeCoding.decode(KeepAwakeReply.self, from: Data(#"{"state":\#(json)}"#.utf8)), "reply: \(json)")
            XCTAssertNil(legacyDecode(KeepAwakeLegacy.State.self, Data(json.utf8)), "4.3.0 read it, so the line must move: \(json)")
            try Data(#"{"ownsFlag":true,"sleepOwed":true,"state":\#(json),"version":1}"#.utf8).write(to: stateFile.url)
            XCTAssertNil(stateFile.load(), json)
            XCTAssertFalse(stateFile.loadOwnsFlag(), json)
            XCTAssertFalse(stateFile.loadSleepOwed(), json)
        }
    }

    /// A reply whose `state` or `failure` cannot be read is still no reply, whatever else it carries.
    func testAReplyWhoseStateOrFailureIsUnreadableStillFailsWhateverElseItCarries() {
        for json in [
            #"{"state":{"paused":{}},"thermal":"fair","thermalGuard":true}"#,
            #"{"state":{"idle":{}},"failure":{"melted":{}},"thermal":"fair","thermalGuard":true}"#,
            #"{"thermal":"fair","thermalGuard":true}"#,
            #"{"state":null,"thermalGuard":true}"#,
        ] {
            XCTAssertNil(KeepAwakeCoding.decode(KeepAwakeReply.self, from: Data(json.utf8)), json)
        }
    }

    /// The five reasons 4.3.0 knows always round-trip as themselves; only the one new reason is
    /// written as another.
    func testOnlyOverheatedTravelsAsAnotherReasonAndEveryReasonRoundTrips() throws {
        for reason in KeepAwakeEndReason.allCases {
            let state = KeepAwakeState.ended(at: t0 + 5, reason: reason)
            XCTAssertEqual(KeepAwakeCoding.decode(KeepAwakeState.self, from: KeepAwakeCoding.encode(state)), state)
            XCTAssertEqual(reason.olderBuildsRead == reason, reason != .overheated, "\(reason)")
            let text = String(decoding: KeepAwakeCoding.encode(state), as: UTF8.self)
            XCTAssertEqual(text.contains("cause"), reason == .overheated, text)
        }
    }
}

// MARK: - The app against the real service

/// Spec § Plan decisions accepted by the session items 5, 6 and 12 and § Settings: the model talks
/// to the real service over the real coding (encode, then decode, as XPC does), against the fake
/// machine. A helper that predates the guard is simulated with 4.3.0's reply bytes and no
/// `setThermalGuard` selector.
final class KeepAwakeThermalGuardLoopVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeDirectory("KeepAwakeThermalGuardLoopVerificationTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor private final class Setting {
        var guardOn = true
        var floorOn = true
    }

    /// Holds a reply until the test opens it, as a slow connection would.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [KeepAwakeRequest] = []
        private var _old = false
        private var _refused: [KeepAwakeRequest] = []
        private var _now = t0
        private var _gate: Gate?
        private var _loseNextArm = false
        var gate: Gate? { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
        var loseNextArm: Bool { get { lock.withLock { _loseNextArm } } set { lock.withLock { _loseNextArm = newValue } } }
        var requests: [KeepAwakeRequest] { lock.withLock { _requests } }
        var refused: [KeepAwakeRequest] { lock.withLock { _refused } }
        var old: Bool { get { lock.withLock { _old } } set { lock.withLock { _old = newValue } } }
        var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
        func record(_ request: KeepAwakeRequest) { lock.withLock { _requests.append(request) } }
        func refuse(_ request: KeepAwakeRequest) { lock.withLock { _refused.append(request) } }
    }

    @MainActor private struct Loop {
        var model: KeepAwakeModel
        var service: KeepAwakeService
        var fake: FakeKeepAwakeMachine
        var wire: Wire
        var setting: Setting
        var helper: KeepAwakeFakeHelper

        var sets: [Bool] {
            wire.requests.compactMap { if case .setThermalGuard(let enabled) = $0 { return enabled } else { return nil } }
        }
    }

    @MainActor private func makeLoop() async -> Loop {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = closedLid }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("loop.json")))
        _ = await service.start(now: t0)
        let wire = Wire()
        let setting = Setting()
        let helper = KeepAwakeFakeHelper(statuses: [.enabled])
        var dependencies = helper.dependencies()
        dependencies.send = { request in
            wire.record(request)
            let now = wire.now
            if wire.old, case .setThermalGuard = request {
                wire.refuse(request)
                return .failure(.helperUnavailable(reason: "unrecognized selector"))
            }
            let reply: KeepAwakeReply
            switch request {
            case .arm(let seconds, let floor): reply = await service.arm(seconds: seconds, floorEnabled: floor, now: now)
            case .disarm: reply = await service.disarm(now: now)
            case .setFloor(let enabled): reply = await service.setFloor(enabled: enabled, now: now)
            case .setThermalGuard(let enabled): reply = await service.setThermalGuard(enabled: enabled, now: now)
            case .state: reply = await service.state(now: now)
            }
            if case .setThermalGuard = request, let gate = wire.gate { await gate.wait() }
            if case .arm = request, wire.loseNextArm {
                wire.loseNextArm = false
                return .failure(.helperTimedOut)
            }
            var data = KeepAwakeCoding.encode(reply)
            if wire.old {
                // A 4.3.0 helper answers with the two keys it has.
                let legacyState: KeepAwakeLegacy.State
                switch reply.state {
                case .idle: legacyState = .idle
                case .armed(let deadline, let floor): legacyState = .armed(deadline: deadline, floorEnabled: floor)
                case .ended(let at, let reason): legacyState = .ended(at: at, reason: KeepAwakeLegacy.EndReason(rawValue: reason.olderBuildsRead.rawValue)!)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .secondsSince1970
                data = (try? encoder.encode(KeepAwakeLegacy.Reply(state: legacyState, failure: reply.failure))) ?? Data()
            }
            guard let decoded = KeepAwakeCoding.decode(KeepAwakeReply.self, from: data) else { return .failure(.unreadableReply) }
            return .success(decoded)
        }
        let model = KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { setting.floorOn },
            rememberDuration: { _ in },
            resetSettings: {},
            thermalGuardEnabled: { setting.guardOn }
        )
        fake.with { $0.calls = [] }
        return Loop(model: model, service: service, fake: fake, wire: wire, setting: setting, helper: helper)
    }

    /// Settings off, Apply, poll: the helper holds the guard off from the Apply's reply on, a hot
    /// closed Mac ends nothing; switched on, the next reading ends the mode and the app shows the end.
    @MainActor func testAGuardSwitchedOffInSettingsSurvivesApplyAndPollsAndSwitchedOnEndsTheMode() async {
        let loop = await makeLoop()
        loop.setting.guardOn = false
        loop.fake.with { $0.thermal = .critical }
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(loop.sets, [false], "Apply turned the guard on; the setting's off went out after it")
        XCTAssertEqual(loop.model.helperThermalGuard, false)
        for minute in 1...5 {
            loop.wire.now = t0 + Double(minute) * 60
            _ = await loop.service.tick(now: loop.wire.now)
            await loop.model.pollIfNeeded(now: loop.wire.now)
        }
        XCTAssertTrue(loop.model.state.isArmed, "guard off, critical, lid closed: five minutes, nothing ends")
        XCTAssertEqual(loop.sets, [false], "polls that agree send nothing")
        XCTAssertEqual(loop.fake.with { $0.calls.filter { $0 == "sleepnow" } }, [])

        loop.setting.guardOn = true
        loop.wire.now = t0 + 310
        await loop.model.thermalGuardChanged(now: loop.wire.now)
        XCTAssertEqual(loop.sets, [false, true])
        XCTAssertEqual(loop.model.helperThermalGuard, true)
        XCTAssertTrue(loop.model.state.isArmed, "turning it on reads no level")
        loop.wire.now = t0 + 360
        _ = await loop.service.tick(now: loop.wire.now)
        await loop.model.pollIfNeeded(now: loop.wire.now)
        XCTAssertEqual(loop.model.state, .ended(at: t0 + 360, reason: .overheated))
        XCTAssertEqual(loop.fake.with { $0.flag }, .cleared)
        XCTAssertEqual(loop.fake.with { $0.calls.last }, "sleepnow")
        let status = KeepAwakeCopy.status(registration: .ready, state: loop.model.state, dismissedThrough: 0, now: t0 + 400)
        XCTAssertEqual(status, .ended(at: t0 + 360, reason: .overheated))
    }

    /// "A flip, then Cancel, then Apply": Cancel leaves the helper's guard as the last send made
    /// it, and the next Apply turns it on again and is corrected from its own reply.
    @MainActor func testAFlipThenCancelThenApplyEndsWithTheHelperHoldingTheSetting() async {
        let loop = await makeLoop()
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(loop.sets, [])
        loop.setting.guardOn = false
        loop.wire.now = t0 + 10
        await loop.model.thermalGuardChanged(now: t0 + 10)
        XCTAssertEqual(loop.sets, [false])
        loop.wire.now = t0 + 20
        await loop.model.cancel(now: t0 + 20)
        XCTAssertFalse(loop.model.state.isArmed)
        XCTAssertEqual(loop.sets, [false], "an ended mode is sent nothing")
        loop.wire.now = t0 + 30
        await loop.model.arm(days: 0, hours: 1, minutes: 0, now: t0 + 30)
        XCTAssertEqual(loop.sets, [false, false], "the new Apply turned it on and the setting's off went out again")
        XCTAssertEqual(loop.model.helperThermalGuard, false)
        loop.fake.with { $0.thermal = .critical }
        loop.wire.now = t0 + 100
        _ = await loop.service.tick(now: loop.wire.now)
        await loop.model.pollIfNeeded(now: loop.wire.now)
        XCTAssertTrue(loop.model.state.isArmed, "the second mode runs with the guard off")
    }

    /// An update during an armed mode, and a reinstall: replies lose and regain the guard field.
    /// The model sends nothing to the helper that has none, and one correction to the one that has.
    @MainActor func testAHelperReplacedByAnOlderOneMidModeAndBackIsAskedNothingUntilItHasTheGuardAgain() async {
        let loop = await makeLoop()
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(loop.model.helperThermalGuard, true)
        XCTAssertNil(KeepAwakeCopy.guardPendingLine(.armed(deadline: t0 + 7_200), helperGuard: loop.model.helperThermalGuard, settingOn: true))

        loop.wire.old = true
        loop.setting.guardOn = false
        await loop.model.pollIfNeeded(now: t0 + 60)
        XCTAssertNil(loop.model.helperThermalGuard, "a reply without the field")
        XCTAssertEqual(
            KeepAwakeCopy.guardPendingLine(.armed(deadline: t0 + 7_200), helperGuard: loop.model.helperThermalGuard, settingOn: true),
            "The heat guard starts with the next Apply."
        )
        loop.setting.guardOn = true
        await loop.model.thermalGuardChanged(now: t0 + 70)
        loop.setting.guardOn = false
        await loop.model.thermalGuardChanged(now: t0 + 80)
        await loop.model.pollIfNeeded(now: t0 + 90)
        await loop.model.floorChanged(false, now: t0 + 100)
        XCTAssertEqual(loop.sets, [], "no setThermalGuard to a helper that never said it has one")
        XCTAssertEqual(loop.wire.refused, [])

        loop.wire.old = false
        loop.wire.now = t0 + 120
        await loop.model.pollIfNeeded(now: t0 + 120)
        XCTAssertEqual(loop.sets, [false], "the helper holds it on, the setting is off: one correction")
        XCTAssertEqual(loop.model.helperThermalGuard, false)
        await loop.model.pollIfNeeded(now: t0 + 180)
        XCTAssertEqual(loop.sets, [false], "they agree now")
    }

    /// Settings › Advanced › Reset all settings (item 12): the settings go back to their defaults
    /// (the floor on, the guard off), and an armed helper that holds both away from them hears
    /// both, the floor's first.
    @MainActor func testResetAllSettingsLeavesAnArmedHelperWithTheFloorOnAndTheGuardOff() async {
        let loop = await makeLoop()
        loop.setting.guardOn = true
        loop.setting.floorOn = false
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(loop.sets, [])
        // `resetEverything`: the store goes back to its defaults, then the two switches are sent.
        loop.setting.guardOn = SettingsStore.Defaults.keepAwakeThermalGuardEnabled
        loop.setting.floorOn = SettingsStore.Defaults.keepAwakeFloorEnabled
        await loop.model.floorChanged(SettingsStore.Defaults.keepAwakeFloorEnabled, now: t0 + 30)
        await loop.model.thermalGuardChanged(now: t0 + 30)
        let reply = await loop.service.state(now: t0 + 40)
        XCTAssertEqual(reply.thermalGuard, false)
        XCTAssertEqual(reply.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(loop.model.helperThermalGuard, false)
        XCTAssertEqual(loop.sets.last, false)
    }
    /// "The app reconciles after EVERY reply while armed": a reply that says the mode is over is not
    /// answered, even when the helper's guard differs from the setting.
    @MainActor func testAReplyThatEndsTheModeIsNotAnsweredWithTheGuard() async {
        let loop = await makeLoop()
        loop.setting.guardOn = false
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertEqual(loop.sets, [false])
        loop.setting.guardOn = true                    // moved with no call to the helper (nothing is armed to hear it)
        loop.wire.now = t0 + 30
        await loop.model.cancel(now: t0 + 30)
        XCTAssertFalse(loop.model.state.isArmed)
        XCTAssertEqual(loop.model.helperThermalGuard, false, "the cancel's reply still says what the helper holds")
        XCTAssertEqual(loop.sets, [false], "an ended mode is sent nothing")
    }

    /// The switch reaches a helper whose Apply reply was lost: the mode may be armed, and the
    /// helper's earlier reply carried the guard, so it has the selector.
    @MainActor func testTheSwitchReachesAHelperWhoseApplyReplyWasLost() async {
        let loop = await makeLoop()
        await loop.model.refresh(now: t0)
        XCTAssertEqual(loop.model.helperThermalGuard, true)
        loop.setting.guardOn = false
        loop.wire.loseNextArm = true
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        XCTAssertFalse(loop.model.state.isArmed, "the reply was lost: the app does not know")
        XCTAssertEqual(loop.sets, [])
        await loop.model.thermalGuardChanged(now: t0 + 5)
        XCTAssertEqual(loop.sets, [false])
        let held = await loop.service.state(now: t0 + 6).thermalGuard
        XCTAssertEqual(held, false)
        XCTAssertTrue(loop.model.state.isArmed, "the switch's reply brought the state")
    }

    /// A switch that moves while a call is out is sent when it returns, as long as the helper that
    /// answered still takes it: a reply without the field (a helper replaced meanwhile) ends it.
    @MainActor func testAFlipWhileACallIsOutIsNotSentToAHelperThatAnsweredWithoutTheGuard() async {
        let loop = await makeLoop()
        await loop.model.arm(days: 0, hours: 2, minutes: 0, now: t0)
        let gate = Gate()
        loop.wire.gate = gate
        loop.setting.guardOn = false
        let first = Task { @MainActor in await loop.model.thermalGuardChanged(now: t0 + 10) }
        while loop.sets.isEmpty { await Task.yield() }
        loop.setting.guardOn = true                    // flips while the call is out
        loop.wire.old = true                           // and the answer comes from a helper without the guard
        await gate.open()
        await first.value
        XCTAssertEqual(loop.sets, [false], "no second call")
        XCTAssertEqual(loop.wire.refused, [])
        XCTAssertNil(loop.model.helperThermalGuard)
    }
}

// MARK: - The engine's sleep rule for a reading

/// Spec § Rule: "Ending follows the existing path: the flag is cleared and, the lid being closed,
/// `pmset sleepnow` runs." The engine's output for a reading says to sleep only with the lid closed.
final class KeepAwakeThermalGuardEngineVerificationTests: XCTestCase {
    func testAReadingThatSettlesTheDeadlineAsksForSleepOnlyWithTheLidClosed() {
        for lid in [false, true] {
            var engine = KeepAwakeEngine()
            _ = engine.arm(duration: 120, floorEnabled: true, now: t0, lidClosed: lid)
            let output = engine.thermal(level: .nominal, now: t0 + 180, lidClosed: lid)
            XCTAssertEqual(output.state, .ended(at: t0 + 120, reason: .deadline))
            XCTAssertEqual(output.sleepDisabled, false)
            XCTAssertEqual(output.sleepNow, lid, "lid closed: \(lid)")
        }
    }

    func testAnEndForHeatAsksForSleepAndAHotReadingWithTheLidOpenAsksForNothing() {
        var closed = KeepAwakeEngine()
        _ = closed.arm(duration: 7_200, floorEnabled: true, now: t0, lidClosed: true)
        let ended = closed.thermal(level: .critical, now: t0 + 60, lidClosed: true)
        XCTAssertEqual(ended.state, .ended(at: t0 + 60, reason: .overheated))
        XCTAssertEqual(ended.sleepDisabled, false)
        XCTAssertTrue(ended.sleepNow)
        var open = KeepAwakeEngine()
        _ = open.arm(duration: 7_200, floorEnabled: true, now: t0, lidClosed: false)
        let kept = open.thermal(level: .critical, now: t0 + 60, lidClosed: false)
        XCTAssertEqual(kept.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(kept.sleepDisabled, true)
        XCTAssertFalse(kept.sleepNow)
    }
}

// MARK: - The setting

/// Spec § Settings: "default OFF (amended 2026-11-22)". A domain that has no value for the key, as
/// every 4.3.0 install has, reads off.
final class KeepAwakeThermalGuardDefaultVerificationTests: XCTestCase {
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    /// The domain is read by a reader created over it, as the card's (`KeepAwakeSection`) and the
    /// store's at launch are. `SettingsStore.shared` lives for the whole run, and its
    /// `@AppStorage` keeps the value it last read or wrote: a key removed under it reads as that
    /// value, not the default.
    @MainActor func testADomainWithoutTheKeyReadsTheGuardOffAndResetToDefaultsBringsItBack() {
        UserDefaults.standard.removeObject(forKey: SettingsStore.keepAwakeThermalGuardKey)
        XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.keepAwakeThermalGuardKey))
        let readAtLaunch = AppStorage(
            wrappedValue: SettingsStore.Defaults.keepAwakeThermalGuardEnabled,
            SettingsStore.keepAwakeThermalGuardKey
        )
        XCTAssertFalse(readAtLaunch.wrappedValue)
        SettingsStore.shared.keepAwakeThermalGuardEnabled = true
        XCTAssertTrue(SettingsStore.shared.keepAwakeThermalGuardEnabled)
        SettingsStore.shared.resetToDefaults()
        XCTAssertFalse(SettingsStore.shared.keepAwakeThermalGuardEnabled)
    }
}
