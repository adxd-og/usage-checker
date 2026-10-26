import XCTest
import ServiceManagement
@testable import Omelette

// Verification of keep awake, Package 1 (spec 2026-10-26 § Design › Behaviour, § Helper, the
// Settings parts of § UI). The focus is where the sleep flag can be orphaned: every way the mode
// ends, fails or is reset must leave `SleepDisabled` clear, and `pmset sleepnow` must run only
// with the lid closed (and causing sleep) and only after the flag reads clear.
// Everything machine-facing goes through `KeepAwakeMachine` / `KeepAwakeClient.Dependencies`
// (fakes from KeepAwakeServiceTests / KeepAwakeClientTests); the only real processes started are
// `/bin/sh`, `/bin/sleep` and `/usr/bin/head` in `testTheProcessRunner…`.

/// Records what `pmset sleepnow` found when it ran.
private final class SleepRecorder: @unchecked Sendable {
    struct Entry { var flag: KeepAwakeFlagReading; var lid: KeepAwakeLid }
    private let lock = NSLock()
    private var storage: [Entry] = []
    var entries: [Entry] { lock.withLock { storage } }
    func record(_ entry: Entry) { lock.withLock { storage.append(entry) } }
}

private func instrumented(_ fake: FakeKeepAwakeMachine, _ recorder: SleepRecorder) -> KeepAwakeMachine {
    var machine = fake.machine()
    let inner = machine.sleepNow
    machine.sleepNow = {
        let seen = fake.with { ($0.flag, $0.lid) }
        recorder.record(.init(flag: seen.0, lid: seen.1))
        return inner()
    }
    return machine
}

private struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

/// § Behaviour: "Ending while the lid is closed" (deadline, floor, Cancel), "Battery floor",
/// "Floor switch while armed"; § Helper: every transition applies the flag and checks it took.
final class KeepAwakeVerificationServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeVerificationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private func started(_ fake: FakeKeepAwakeMachine, machine: KeepAwakeMachine? = nil) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: machine ?? fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    private let closedLid = KeepAwakeLid(closed: true, causesSleep: true)

    // MARK: - Ending with the lid closed, at the service

    func testCancelWithTheLidClosedClearsTheFlagThenSleepsTheMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = closedLid }
        let reply = await service.disarm(now: t0 + 60)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 60, reason: .cancelled), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .cancelled))
    }

    func testCancelOnAnExternalDisplayNeverSleepsTheMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = KeepAwakeLid(closed: true, causesSleep: false) }
        _ = await service.disarm(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
    }

    func testTheBatteryFloorWithTheLidClosedClearsTheFlagThenSleepsTheMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = closedLid; $0.power = KeepAwakePower(onBattery: true, percent: 24) }
        let reply = await service.powerChanged(now: t0 + 600)
        XCTAssertEqual(reply.state, .ended(at: t0 + 600, reason: .batteryFloor))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    /// § Behaviour: the floor switch "reaches the daemon at once" — turned on while the battery
    /// is already low, the mode ends there and then, flag cleared and, lid closed, the Mac asleep.
    func testTurningTheFloorOnWhileLowEndsTheModeAndSleepsAClosedMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: false, now: t0)
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        let stillOn = await service.powerChanged(now: t0 + 60)
        XCTAssertEqual(stillOn.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
        fake.with { $0.calls = []; $0.lid = closedLid }
        let reply = await service.setFloor(enabled: true, now: t0 + 120)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 120, reason: .batteryFloor), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
    }

    // MARK: - Failed arms never leave the flag behind

    /// Rule 4 with an armed mode before: a replacement the flag write refuses keeps the old
    /// deadline, and the flag stays on for it.
    func testAReplacementThePmsetRefusesKeepsTheOldDeadlineAndTheFlagOn() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.failSetsRemaining = 1; $0.calls = [] }
        let reply = await service.arm(seconds: 1_800, floorEnabled: false, now: t0 + 60)
        XCTAssertEqual(reply.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(reply.failure, .commandFailed(command: "pmset", status: 1))
        XCTAssertEqual(fake.with { $0.flag }, .set)
        XCTAssertEqual(stateFile.load(), .armed(deadline: t0 + 7_200, floorEnabled: true))
        let tick = await service.tick(now: t0 + 120)
        XCTAssertEqual(tick, KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
    }

    /// The worst arm: the flag really went on, the read-back did not say so, and the rollback's
    /// clear fails as well. The service must not forget the flag: retry within a minute, no idle
    /// exit meanwhile.
    func testAnArmWhoseRollbackCannotClearTheFlagIsRetriedWithinAMinute() async {
        let fake = FakeKeepAwakeMachine()
        let counters = LockedCounters()
        var machine = fake.machine()
        let innerSet = machine.setSleepDisabled
        let innerRead = machine.readSleepDisabled
        machine.setSleepDisabled = { value in
            // 1st call: arm's set 1 works; 2nd call: the rollback's clear fails; then normal.
            let n = counters.bump("set")
            if n == 2 { return KeepAwakeCommandResult(status: 1, output: "") }
            return innerSet(value)
        }
        machine.readSleepDisabled = {
            // The first read, right after arm's set 1, is unreadable.
            if counters.bump("read") == 1 { return .unreadable }
            return innerRead()
        }
        let service = await started(fake, machine: machine)
        counters.reset()
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(reply.state, .idle)
        XCTAssertEqual(reply.failure, .readBack(expected: true))
        XCTAssertEqual(fake.with { $0.flag }, .set, "the flag really is on: the rollback could not clear it")
        XCTAssertEqual(fake.with { $0.scheduled }.last ?? nil, t0 + 60, "a retry is scheduled")
        await service.exitIfIdle(now: t0 + 3_600)
        XCTAssertEqual(fake.with { $0.terminations }, [], "an unknown flag holds the daemon")
        let retry = await service.tick(now: t0 + 60)
        XCTAssertEqual(retry.state, .idle)
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
    }

    // MARK: - Battery reading at the moment of Apply

    /// § Behaviour › Battery floor: "On battery and below 25 %". A Mac plugged in since the last
    /// reading the daemon took (a missed notification: the tick exists for those, plan D10) must
    /// not have its Apply refused for a battery level the charger has already made irrelevant.
    func testApplyOnTheChargerIsNotEndedByAStaleLowBatteryReading() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 20) }
        _ = await service.powerChanged(now: t0)
        fake.with { $0.power = KeepAwakePower(onBattery: false, percent: 20) }
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 600)
        XCTAssertEqual(reply.state, .armed(deadline: t0 + 7_800, floorEnabled: true))
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    // MARK: - Idle exit and connection bookkeeping

    /// The listener reports opens and closes from unordered tasks (`Task { await … }` in the
    /// delegate and the invalidation handler), so each connection carries an id: a close that
    /// lands before its own open means that connection is already gone, and its late open must
    /// not count — otherwise the daemon would stay resident forever (session ruling T4,
    /// 2026-10-26). A second, live connection still holds the daemon.
    func testACloseThatLandsBeforeItsOpenIsAGoneConnectionAndALiveOneStillHoldsTheDaemon() async {
        let gone = FakeKeepAwakeMachine()
        let goneService = await started(gone)
        await goneService.connectionClosed(id: 1, now: t0 + 1)
        await goneService.connectionOpened(id: 1, now: t0 + 2)
        await goneService.exitIfIdle(now: t0 + 3_600)
        XCTAssertEqual(gone.with { $0.terminations }, [0], "a connection closed before its open is not open")

        let live = FakeKeepAwakeMachine()
        let liveService = await started(live)
        await liveService.connectionClosed(id: 1, now: t0 + 1)
        await liveService.connectionOpened(id: 2, now: t0 + 2)
        await liveService.connectionOpened(id: 1, now: t0 + 3)
        await liveService.exitIfIdle(now: t0 + 3_600)
        XCTAssertEqual(live.with { $0.terminations }, [], "connection 2 is still open")
    }

    func testAnIdleDaemonExitsExactlyWhenItsMinuteIsUp() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.state(now: t0 + 100)
        XCTAssertEqual(fake.with { $0.exits }.last ?? nil, t0 + 160)
        await service.exitIfIdle(now: t0 + 159.9)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        await service.exitIfIdle(now: t0 + 160)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    // MARK: - Stop

    func testAStopWithTheLidClosedAfterTheDeadlineStillNeverSleepsTheMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 60, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = closedLid }
        await service.terminate(now: t0 + 90)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 90, reason: .deadline))
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    /// Plan D8: the file is written "on every start", not only when the state changed — a start
    /// that finds nothing (or garbage) leaves a readable `idle` behind for the next restart.
    func testAStartWritesTheStateFileEvenWhenNothingChanged() async throws {
        let fake = FakeKeepAwakeMachine()
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0)
        XCTAssertEqual(stateFile.load(), .idle)
        try Data("not json".utf8).write(to: stateFile.url)
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0 + 60)
        XCTAssertEqual(stateFile.load(), .idle)
    }

    /// A start that cannot clear the flag leaves a retry scheduled and keeps the daemon alive.
    func testAStartWhoseClearFailsKeepsRetryingAndNeverExits() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.setStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply.failure, .commandFailed(command: "pmset", status: 1))
        XCTAssertEqual(fake.with { $0.scheduled }.last ?? nil, t0 + 60)
        await service.exitIfIdle(now: t0 + 10_000)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        fake.with { $0.setStatus = 0 }
        _ = await service.tick(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
        await service.exitIfIdle(now: t0 + 60 + 60)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }
}

private final class LockedCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ key: String) -> Int { lock.withLock { counts[key, default: 0] += 1; return counts[key]! } }
    func reset() { lock.withLock { counts = [:] } }
}

/// Invariants of the whole daemon core, over seeded random sequences of every input with pmset
/// failures injected: (1) after an input that met no fault, the flag is on exactly while the
/// mode is armed; (2) after a fault and one retry tick, the same; (3) `pmset sleepnow` only ever
/// ran with the flag clear and a lid that is closed and causes sleep; (4) a mode that ends in an
/// input with no fault sleeps the Mac exactly when the lid sleeps, once; (5) the daemon never
/// agrees to exit while armed or while the flag reads set; (6) an armed mode never survives a
/// battery reading below the floor taken on a tick or notification, nor its own deadline.
final class KeepAwakeVerificationFuzzTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeVerificationFuzzTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Coverage {
        var armedSteps = 0
        var endings = 0
        var sleeps = 0
        var faults = 0
        var exits = 0
    }

    func testTheFlagIsOnExactlyWhileTheModeIsArmedAcrossRandomHistories() async {
        var total = Coverage()
        for seed in [1, 2, 3, 5, 8, 13, 21, 34] as [UInt64] {
            let c = await run(seed: seed, steps: 300)
            total.armedSteps += c.armedSteps; total.endings += c.endings; total.sleeps += c.sleeps
            total.faults += c.faults; total.exits += c.exits
        }
        // The walk must actually reach the interesting states, or the invariants prove nothing.
        XCTAssertGreaterThan(total.armedSteps, 100)
        XCTAssertGreaterThan(total.endings, 50)
        XCTAssertGreaterThan(total.sleeps, 10)
        XCTAssertGreaterThan(total.faults, 100)
        XCTAssertGreaterThan(total.exits, 50)
    }

    private func run(seed: UInt64, steps: Int) async -> Coverage {
        var coverage = Coverage()
        var rng = SeededRandom(state: seed)
        let fake = FakeKeepAwakeMachine()
        let recorder = SleepRecorder()
        let service = KeepAwakeService(
            machine: instrumented(fake, recorder),
            stateFile: KeepAwakeStateFile(url: directory.appendingPathComponent("seed-\(seed).json"))
        )
        var now = t0
        _ = await service.start(now: now)
        var previous: KeepAwakeState = .idle
        var checkedSleeps = 0

        for step in 0..<steps {
            let tag = "seed \(seed) step \(step)"
            now += TimeInterval(rng.int(400))
            let action = rng.int(8)
            let faulted = rng.int(6) == 0
            if faulted {
                if rng.int(2) == 0 { fake.with { $0.setStatus = 1 } } else { fake.with { $0.setTakes = false } }
            }
            var checksFloor = false
            let sleepsBefore = recorder.entries.count
            let reply: KeepAwakeReply
            switch action {
            case 0, 1:
                reply = await service.arm(seconds: TimeInterval(60 + rng.int(7_200)), floorEnabled: rng.int(4) != 0, now: now)
            case 2:
                reply = await service.disarm(now: now)
            case 3:
                reply = await service.tick(now: now)
                checksFloor = true
            case 4:
                // A notification always carries a reading; one without would not settle anything.
                let onBattery = rng.int(2) == 0
                fake.with { $0.power = KeepAwakePower(onBattery: onBattery, percent: rng.int(60)) }
                reply = await service.powerChanged(now: now)
                checksFloor = true
            case 5:
                reply = await service.setFloor(enabled: rng.int(2) == 0, now: now)
            case 6:
                fake.with { $0.lid = KeepAwakeLid(closed: rng.int(2) == 0, causesSleep: rng.int(5) != 0) }
                if rng.int(4) == 0 { fake.with { $0.power = nil } }
                reply = await service.state(now: now)
                checksFloor = true
            default:
                reply = await service.state(now: now)
                checksFloor = true
            }
            let lidSleeps = fake.with { $0.lid.sleepsWhenClosed }
            let flagNow = fake.with { $0.flag }
            var settled = reply

            if faulted {
                fake.with { $0.setStatus = 0; $0.setTakes = true }
                now += 60
                settled = await service.tick(now: now)
                XCTAssertEqual(settled.state.isArmed, fake.with { $0.flag } == .set, "after a retry: \(tag)")
            } else {
                // 1.
                XCTAssertNil(reply.failure, tag)
                XCTAssertEqual(reply.state.isArmed, flagNow == .set, "flag vs mode: \(tag) \(reply.state) flag \(flagNow)")
                // 4.
                let delta = recorder.entries.count - sleepsBefore
                let endedHere = previous.isArmed && !reply.state.isArmed
                XCTAssertEqual(delta, endedHere && lidSleeps ? 1 : 0, "sleepnow count: \(tag) \(previous) -> \(reply.state)")
                // 6.
                if let deadline = reply.state.deadline { XCTAssertGreaterThan(deadline, now, "deadline: \(tag)") }
                if checksFloor, let power = fake.with({ $0.power }), KeepAwakeRules.isBelowFloor(power),
                   case .armed(_, let floorEnabled) = reply.state {
                    XCTAssertFalse(floorEnabled, "armed below the floor: \(tag)")
                }
            }
            if settled.state.isArmed { coverage.armedSteps += 1 }
            if previous.isArmed && !settled.state.isArmed { coverage.endings += 1 }
            if faulted { coverage.faults += 1 }
            previous = settled.state

            // 3.
            for entry in recorder.entries[checkedSleeps...] {
                XCTAssertTrue(entry.flag.isClear, "sleepnow with the flag \(entry.flag): \(tag)")
                XCTAssertTrue(entry.lid.sleepsWhenClosed, "sleepnow with the lid \(entry.lid): \(tag)")
            }
            checkedSleeps = recorder.entries.count

            // 5.
            let exitsBefore = fake.with { $0.terminations.count }
            await service.exitIfIdle(now: now + 1_000_000)
            if fake.with({ $0.terminations.count }) > exitsBefore {
                XCTAssertFalse(settled.state.isArmed, "exit while armed: \(tag)")
                XCTAssertTrue(fake.with { $0.flag }.isClear, "exit with the flag on: \(tag)")
                coverage.exits += 1
            }
        }
        coverage.sleeps = recorder.entries.count
        return coverage
    }
}

/// § Behaviour › "Ending while the lid is closed" and the engine's contract, as invariants over
/// every input the engine takes.
final class KeepAwakeVerificationEngineTests: XCTestCase {
    func testTheEngineNeverAsksForSleepWithoutAClosedLidOrWithTheFlagOn() {
        var rng = SeededRandom(state: 99)
        var engine = KeepAwakeEngine()
        var now = Date(timeIntervalSince1970: 1_793_000_000)
        for step in 0..<2_000 {
            now += TimeInterval(rng.int(300))
            let lid = rng.int(2) == 0
            let before = engine.state
            let output: KeepAwakeEngine.Output
            switch rng.int(6) {
            case 0: output = engine.arm(duration: TimeInterval(60 + rng.int(8_000)), floorEnabled: rng.int(3) != 0, now: now, lidClosed: lid)
            case 1: output = engine.disarm(now: now, lidClosed: lid)
            case 2: output = engine.tick(now: now, lidClosed: lid)
            case 3: output = engine.power(onBattery: rng.int(2) == 0, percent: rng.int(60), now: now, lidClosed: lid)
            case 4: output = engine.setFloor(enabled: rng.int(2) == 0, now: now, lidClosed: lid)
            default: output = engine.stop(now: now)
            }
            XCTAssertEqual(output.sleepDisabled, output.state.isArmed, "the flag follows the mode (step \(step))")
            if output.sleepNow {
                XCTAssertTrue(lid && before.isArmed && !output.state.isArmed, "sleepNow only when an armed mode ended on a closed lid (step \(step))")
                XCTAssertFalse(output.sleepDisabled)
            }
            if let deadline = output.state.deadline { XCTAssertGreaterThan(deadline, now) }
        }
    }

    func testAStartNeverLeavesTheFlagOnWhateverTheFileSays() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let files: [KeepAwakeState?] = [
            nil, .idle, .armed(deadline: now + 3_600, floorEnabled: true), .armed(deadline: now - 3_600, floorEnabled: false),
            .ended(at: now - 60, reason: .batteryFloor),
        ]
        for file in files {
            for flagWasSet in [false, true] {
                for lid in [false, true] {
                    var engine = KeepAwakeEngine()
                    let output = engine.start(persisted: file, flagWasSet: flagWasSet, now: now, lidClosed: lid)
                    XCTAssertFalse(output.sleepDisabled, "\(String(describing: file)) \(flagWasSet) \(lid)")
                    XCTAssertFalse(output.state.isArmed)
                    XCTAssertEqual(output.sleepNow, flagWasSet && lid, "\(String(describing: file)) \(flagWasSet) \(lid)")
                }
            }
        }
    }
}

/// § Helper › App side and § UI › Reset keep awake: the order of disarm, flag read, password
/// prompt and unregister, over every combination of what the machine can answer.
final class KeepAwakeVerificationClientTests: XCTestCase {
    private struct Boom: Error {}

    func testResetOnlyEverUnregistersAfterTheFlagReadsClearAndPromptsOnlyForASetFlag() async {
        let statuses: [SMAppService.Status] = [.enabled, .requiresApproval, .notRegistered]
        let firsts: [KeepAwakeFlagReading] = [.set, .cleared, .neverSet, .unreadable]
        let seconds: [KeepAwakeFlagReading] = [.set, .cleared, .neverSet, .unreadable]
        let admins: [KeepAwakeFailure?] = [nil, .adminCancelled]
        let unregisterErrors: [Bool] = [false, true]
        var combos = 0
        for status in statuses {
            for first in firsts {
                for second in seconds {
                    for admin in admins {
                        for unregisterFails in unregisterErrors {
                            combos += 1
                            let helper = KeepAwakeFakeHelper(statuses: [status, status])
                            helper.with { s in
                                s.flags = [first, second]
                                s.adminResult = admin
                                if unregisterFails { s.unregisterError = Boom() }
                            }
                            let client = KeepAwakeClient(dependencies: helper.dependencies())
                            let outcome = await client.reset()
                            let calls = helper.calls
                            let label = "\(status) \(first) \(second) \(String(describing: admin)) \(unregisterFails) -> \(calls)"
                            let prompted = calls.contains("adminClear")
                            let unregistered = calls.contains("unregister")
                            XCTAssertEqual(prompted, first == .set, "the prompt only for a set flag: \(label)")
                            XCTAssertEqual(calls.filter { $0 == "adminClear" }.count, prompted ? 1 : 0, label)
                            XCTAssertEqual(calls.contains("send"), status == .enabled, "disarm only a ready helper: \(label)")
                            let finalFlag = first == .set ? second : first
                            XCTAssertEqual(outcome.flag, finalFlag, label)
                            if unregistered {
                                XCTAssertTrue(finalFlag.isClear, "unregistered with the flag \(finalFlag): \(label)")
                                XCTAssertNotEqual(status, .notRegistered)
                            }
                            if finalFlag.isClear, status != .notRegistered {
                                XCTAssertTrue(unregistered, "a clear flag always lets the helper go: \(label)")
                            }
                            if !finalFlag.isClear {
                                XCTAssertFalse(outcome.isComplete, label)
                                XCTAssertTrue(helper.with { $0.registeredBuild } != nil, "the build is remembered while the helper stays: \(label)")
                            }
                            if outcome.isComplete {
                                XCTAssertTrue(finalFlag.isClear, label)
                                if admin == nil || first != .set { XCTAssertNil(outcome.failure, label) }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(combos, 3 * 4 * 4 * 2 * 2)
    }
}

/// Pure rules and parsers.
final class KeepAwakeVerificationPureTests: XCTestCase {
    /// D11: the remembered minutes lose nothing: every legal total goes through the three
    /// steppers and back to the same seconds.
    func testEveryWholeMinuteFromOneMinuteToSevenDaysRoundTripsThroughTheSteppers() {
        for minutes in 1...10_080 {
            let parts = KeepAwakeRules.parts(totalMinutes: minutes)
            XCTAssertTrue((0...7).contains(parts.days) && (0...23).contains(parts.hours) && (0...59).contains(parts.minutes), "\(minutes)")
            XCTAssertEqual(KeepAwakeRules.duration(days: parts.days, hours: parts.hours, minutes: parts.minutes), TimeInterval(minutes * 60), "\(minutes)")
        }
    }

    func testAbsurdStepperValuesNeverTrapAndStayInsideTheCap() {
        XCTAssertEqual(KeepAwakeRules.duration(days: Int.max, hours: Int.max, minutes: Int.max), 604_800)
        XCTAssertNil(KeepAwakeRules.duration(days: Int.min, hours: Int.min, minutes: Int.min))
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: -3, minutes: 0), 604_800)
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: Int.max), KeepAwakeRules.Parts(days: 7, hours: 0, minutes: 0))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: Int.min), KeepAwakeRules.Parts(days: 0, hours: 0, minutes: 1))
    }

    func testOnlyTheFlagsOwnLineCountsAndTheFirstOneDecides() {
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabledX\t\t1\n"), .neverSet)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " NotSleepDisabled 1\n"), .neverSet)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabled\t\t1\n SleepDisabled\t\t0\n"), .set)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabled\t\t0\r\n sleep 1\r\n"), .cleared)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: "SleepDisabled 1"), .set)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: ""), .neverSet)
        XCTAssertEqual(KeepAwakeReadings.flag(fromPmset: " SleepDisabled\t\t01\n"), .unreadable)
    }

    func testTheInternalBatteryIsPickedOutOfSeveralPowerSources() {
        let ups: [String: Any] = ["Type": "UPS", "Is Present": true, "Power Source State": "AC Power", "Current Capacity": 99, "Max Capacity": 100]
        let internalBattery: [String: Any] = [
            "Type": "InternalBattery", "Power Source State": "Battery Power", "Current Capacity": 20, "Max Capacity": 100,
        ]
        XCTAssertEqual(KeepAwakeReadings.power(fromDescriptions: [ups, internalBattery]), KeepAwakePower(onBattery: true, percent: 20))
        let noCapacity: [String: Any] = ["Type": "InternalBattery", "Power Source State": "Battery Power"]
        XCTAssertNil(KeepAwakeReadings.power(fromDescriptions: [noCapacity]))
        let noMax: [String: Any] = ["Type": "InternalBattery", "Power Source State": "AC Power", "Current Capacity": 80]
        XCTAssertEqual(KeepAwakeReadings.power(fromDescriptions: [noMax]), KeepAwakePower(onBattery: false, percent: 80))
    }

    /// The floor is "below 25 %": 24.99 % reads as 24 and ends the mode, 25.0 % does not.
    func testTheFloorBoundaryFollowsTheRoundedDownPercent() {
        func power(_ current: Int, _ maximum: Int) -> KeepAwakePower? {
            KeepAwakeReadings.power(fromDescriptions: [[
                "Type": "InternalBattery", "Is Present": true, "Power Source State": "Battery Power",
                "Current Capacity": current, "Max Capacity": maximum,
            ]])
        }
        XCTAssertEqual(power(2_499, 10_000)?.percent, 24)
        XCTAssertEqual(power(2_500, 10_000)?.percent, 25)
        XCTAssertTrue(power(2_499, 10_000).map(KeepAwakeRules.isBelowFloor) ?? false)
        XCTAssertFalse(power(2_500, 10_000).map(KeepAwakeRules.isBelowFloor) ?? true)
    }

    func testAFailureWrittenBesideTheStateIsDroppedByTheNextPlainWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeepAwakeVerificationPureTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try file.save(.ended(at: t0, reason: .stopped), failure: .readBack(expected: false))
        XCTAssertEqual(file.loadFailure(), .readBack(expected: false))
        try file.save(.idle)
        XCTAssertNil(file.loadFailure())
        XCTAssertEqual(file.load(), .idle)
    }

    /// The daemon's only process runner: what keeps a hung or noisy pmset from hanging the
    /// daemon with the flag on. Only /bin/sh, /bin/sleep and /usr/bin/head are started.
    func testTheProcessRunnerReportsStatusAndBothStreams() {
        let result = KeepAwakeCommand.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.output.contains("out") && result.output.contains("err"), result.output)
    }

    func testAToolThatCannotStartComesBackAsMinusOne() {
        XCTAssertEqual(KeepAwakeCommand.run("/nonexistent/omelette-tool", [], timeout: 10).status, -1)
    }

    func testAToolThatOutlivesItsTimeoutIsTerminated() {
        let started = Date()
        let result = KeepAwakeCommand.run("/bin/sleep", ["60"], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertNotEqual(result.status, 0)
    }

    func testALargeOutputDoesNotDeadlockTheRunner() {
        let result = KeepAwakeCommand.run("/usr/bin/head", ["-c", "300000", "/dev/zero"], timeout: 20)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 300_000)
    }
}
