import XCTest
@testable import Omelette

/// pmset, the lid, the battery and the tick timer, faked. `flag` is what `pmset -g` reads;
/// a set with status 0 moves it unless `setTakes` is false; `sleepStatus` is what
/// `pmset sleepnow` exits with.
final class FakeKeepAwakeMachine: @unchecked Sendable {
    struct Storage {
        var calls: [String] = []
        var scheduled: [Date?] = []
        var flag: KeepAwakeFlagReading = .neverSet
        var setStatus: Int32 = 0
        var setTakes = true
        var sleepStatus: Int32 = 0
        /// This Mac's reading: lid open, closing it would sleep.
        var lid = KeepAwakeLid(closed: false, causesSleep: true)
        var power: KeepAwakePower?
        var exits: [Date?] = []
        var terminations: [Int32] = []
        var pauses: [TimeInterval] = []
        var failSetsRemaining = 0
    }
    private let lock = NSLock()
    private var storage = Storage()

    func with<T>(_ body: (inout Storage) -> T) -> T { lock.withLock { body(&storage) } }

    func machine() -> KeepAwakeMachine {
        KeepAwakeMachine(
            setSleepDisabled: { value in
                self.with { s in
                    s.calls.append("set \(value ? 1 : 0)")
                    let status: Int32 = s.failSetsRemaining > 0 ? 1 : s.setStatus
                    if s.failSetsRemaining > 0 { s.failSetsRemaining -= 1 }
                    if status == 0, s.setTakes { s.flag = value ? .set : .cleared }
                    return KeepAwakeCommandResult(status: status, output: "")
                }
            },
            readSleepDisabled: { self.with { s in s.calls.append("read"); return s.flag } },
            sleepNow: { self.with { s in s.calls.append("sleepnow"); return KeepAwakeCommandResult(status: s.sleepStatus, output: "") } },
            lid: { self.with { $0.lid } },
            power: { self.with { $0.power } },
            schedule: { date in self.with { $0.scheduled.append(date) } },
            scheduleExit: { date in self.with { $0.exits.append(date) } },
            terminate: { status in self.with { $0.terminations.append(status) } },
            pause: { seconds in self.with { $0.pauses.append(seconds) } }
        )
    }
}

/// Spec 2026-10-26 § Helper: the daemon wires the engine to `pmset -a disablesleep <0|1>`
/// (reading back `pmset -g`), a one-minute wall-clock tick and power notifications; every
/// transition writes the state file; a pmset failure comes back as an error. Plan Task 9
/// rules 1–8, with review C4 (an owed sleep survives a failed clear) and C5 (a start reads
/// the flag before clearing it).
final class KeepAwakeServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    /// A service past its start, with the start's calls forgotten.
    private func started(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    func testStartClearsTheFlagEvenWhenNothingWasArmed() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read"], "the flag is read before the clear (C5)")
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
    }

    /// C5: a failed save, then a crash with the lid closed — the file is no help.
    func testACrashWithAnUnsavedArmedStateStillSleepsWithTheLidClosed() async throws {
        try Data("not json".utf8).write(to: stateFile.url)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0, reason: .restarted), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
    }

    func testAStartWithTheFlagClearNeverSleeps() async throws {
        try stateFile.save(.armed(deadline: t0 + 3_600, floorEnabled: true))
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .cleared; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read"])
    }

    func testStartAfterACrashWhileArmedEndsTheModeAsRestarted() async throws {
        try stateFile.save(.armed(deadline: t0 + 3_600, floorEnabled: true))
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0, reason: .restarted), failure: nil))
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .restarted))
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
    }

    func testArmSetsTheFlagReadsItBackAndTicksWithinAMinute() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 1", "read"])
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 60])
        XCTAssertEqual(stateFile.load(), .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    func testAnArmTheFlagDoesNotTakeLeavesTheModeOffAndSaysWhy() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        fake.with { $0.setTakes = false }
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: .readBack(expected: true)))
        XCTAssertEqual(fake.with { $0.calls }, ["set 1", "read", "set 0", "read"])
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
    }

    func testAPmsetFailureComesBackAsAnError() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        fake.with { $0.setStatus = 1 }
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: .commandFailed(command: "pmset", status: 1)))
        XCTAssertEqual(fake.with { $0.calls }, ["set 1", "set 0"])
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 60], "the clear failed too: retry in a minute")
    }

    func testAnInvalidDurationNeverRunsPmset() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        let reply = await service.arm(seconds: 30, floorEnabled: true, now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: .invalidDuration))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.scheduled }, [])
    }

    func testATickBeforeTheDeadlineRunsNoPmset() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = [] }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 120])
    }

    func testTheDeadlineClearsTheFlagAndSleepsWithTheLidClosed() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        let reply = await service.tick(now: t0 + 120)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 120, reason: .deadline))
    }

    func testWithTheLidOpenTheDeadlineOnlyClearsTheFlag() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = [] }
        _ = await service.tick(now: t0 + 120)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
    }

    /// D5 (session ruling): a closed lid in clamshell mode on an external display reads
    /// `AppleClamshellCausesSleep` No, and such a Mac is never put to sleep by us.
    func testOnAnExternalDisplayTheEndNeverSleepsTheMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = KeepAwakeLid(closed: true, causesSleep: false) }
        let reply = await service.tick(now: t0 + 120)
        XCTAssertEqual(reply.state, .ended(at: t0 + 120, reason: .deadline))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
    }

    func testSleepNowWaitsForTheFlagToReadClear() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.setTakes = false; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        let reply = await service.tick(now: t0 + 120)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: .readBack(expected: false)))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 180])
    }

    func testABatteryNotificationBelowTheFloorEndsTheMode() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.power = KeepAwakePower(onBattery: true, percent: 24) }
        let reply = await service.powerChanged(now: t0 + 600)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 600, reason: .batteryFloor), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
    }

    func testTheTickCatchesALowBatteryTheNotificationMissed() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 20) }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .batteryFloor))
    }

    func testWithTheFloorTurnedOffALowBatteryKeepsTheModeOn() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = [] }
        let off = await service.setFloor(enabled: false, now: t0 + 30)
        XCTAssertEqual(off.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
        XCTAssertEqual(fake.with { $0.calls }, [], "the flag is already on")
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 5) }
        let reply = await service.powerChanged(now: t0 + 60)
        XCTAssertEqual(reply.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
    }

    func testDisarmWhileIdleStillClearsAndReadsBack() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        let reply = await service.disarm(now: t0)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
    }

    /// Review C4: with the lid closed, the sleep the failed clear could not deliver is owed and
    /// runs once the retry reads clear.
    func testAClearThatFailsIsRetriedOnTheNextTickAndTheOwedSleepFollows() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.setStatus = 1; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        let failed = await service.tick(now: t0 + 120)
        XCTAssertEqual(failed, KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: .commandFailed(command: "pmset", status: 1)))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0"], "no sleepnow while the flag is still on")
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 180])
        fake.with { $0.calls = []; $0.scheduled = []; $0.setStatus = 0 }
        let retried = await service.tick(now: t0 + 180)
        XCTAssertEqual(retried, KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
    }

    func testAnOwedSleepIsDroppedWhenTheLidOpens() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.setStatus = 1; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        _ = await service.tick(now: t0 + 120)
        fake.with { $0.calls = []; $0.scheduled = []; $0.setStatus = 0; $0.lid = KeepAwakeLid(closed: false, causesSleep: true) }
        _ = await service.tick(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.scheduled }, [nil], "nothing owed any more")
    }

    func testAFailedSleepnowStaysOwedWhileTheLidStaysClosed() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.sleepStatus = 1; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        _ = await service.tick(now: t0 + 120)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 180], "the sleep is still owed: tick again")
        fake.with { $0.calls = []; $0.scheduled = []; $0.sleepStatus = 0 }
        _ = await service.tick(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.calls }, ["sleepnow"], "the flag is already clear")
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
    }

    func testEveryTransitionIsWrittenToTheStateFile() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(stateFile.load(), .armed(deadline: t0 + 7_200, floorEnabled: true))
        _ = await service.disarm(now: t0 + 60)
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .cancelled))
        let next = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await next.start(now: t0 + 120)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .cancelled))
    }

    func testStateAfterTheDeadlineEndsTheModeWithoutWaitingForATick() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        let early = await service.state(now: t0 + 30)
        XCTAssertEqual(early.state, .armed(deadline: t0 + 120, floorEnabled: true))
        let late = await service.state(now: t0 + 125)
        XCTAssertEqual(late.state, .ended(at: t0 + 125, reason: .deadline))
    }

    // MARK: - Idle exit (session ruling on D7; review C2): not armed, nothing owed, no open
    // connection → the actor itself exits with 0 after 60 s; launchd starts it again on demand.

    func testAStartThatLeavesItIdleExitsAMinuteLater() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        XCTAssertEqual(fake.with { $0.exits }, [t0 + 60])
        await service.exitIfIdle(now: t0 + 59)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        await service.exitIfIdle(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    func testAnArmedDaemonStaysAndTheEndLetsItGoAMinuteLater() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        XCTAssertEqual(fake.with { $0.exits }, [nil])
        await service.exitIfIdle(now: t0 + 119)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        _ = await service.tick(now: t0 + 120)
        XCTAssertEqual(fake.with { $0.exits }, [nil, t0 + 180])
        await service.exitIfIdle(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    func testAnOwedClearHoldsTheDaemonUntilItTakes() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.exits = []; $0.setStatus = 1 }
        _ = await service.tick(now: t0 + 120)
        XCTAssertEqual(fake.with { $0.exits }, [nil])
        await service.exitIfIdle(now: t0 + 600)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        fake.with { $0.setStatus = 0 }
        _ = await service.tick(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.exits }, [nil, t0 + 240])
    }

    /// C4's owed sleep keeps the daemon (and its tick) alive too.
    func testAnOwedSleepHoldsTheDaemonUntilItRuns() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.sleepStatus = 1; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        _ = await service.tick(now: t0 + 120)
        await service.exitIfIdle(now: t0 + 600)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        fake.with { $0.sleepStatus = 0 }
        _ = await service.tick(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.exits }, [nil, nil, t0 + 240])
    }

    func testAnOpenConnectionHoldsItAndClosingItStartsTheMinuteAgain() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.connectionOpened(id: 1, now: t0 + 10)
        XCTAssertEqual(fake.with { $0.exits }, [nil])
        await service.exitIfIdle(now: t0 + 120)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        await service.connectionClosed(id: 1, now: t0 + 20)
        XCTAssertEqual(fake.with { $0.exits }, [nil, t0 + 80])
        await service.exitIfIdle(now: t0 + 79)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        await service.exitIfIdle(now: t0 + 80)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    func testTwoConnectionsHoldItUntilBothClose() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.connectionOpened(id: 1, now: t0)
        await service.connectionOpened(id: 2, now: t0 + 1)
        await service.connectionClosed(id: 1, now: t0 + 2)
        XCTAssertEqual(fake.with { $0.exits }, [nil, nil, nil])
        await service.connectionClosed(id: 2, now: t0 + 3)
        XCTAssertEqual(fake.with { $0.exits }, [nil, nil, nil, t0 + 63])
    }

    func testEveryCallWhileIdleStartsTheMinuteAgain() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.state(now: t0 + 30)
        XCTAssertEqual(fake.with { $0.exits }, [t0 + 90])
        await service.exitIfIdle(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.terminations }, [])
    }

    /// C2: the exit timer was armed for t0 + 60; an app connection and an arm land first.
    /// The timer still fires, and the actor, re-checking, does not exit.
    func testAnArmThatLandsBeforeTheExitTimerFiresNeverTerminates() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.connectionOpened(id: 1, now: t0 + 50)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 55)
        await service.connectionClosed(id: 1, now: t0 + 56)
        await service.exitIfIdle(now: t0 + 60)
        await service.exitIfIdle(now: t0 + 3_600)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    // MARK: - Review C3: SIGTERM (unload, Login Items switch, unregister); P1a: retries, then exit 1

    func testATerminateWhileArmedClearsSavesStoppedAndExits() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }
        await service.terminate(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"], "cleared, and no sleepnow")
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .stopped))
        XCTAssertNil(stateFile.loadFailure())
        XCTAssertEqual(fake.with { $0.pauses }, [])
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    /// P1a: the flag still reads 1 after three tries, 2 s apart — record why and exit 1, so
    /// launchd restarts a still-loaded job and its start clears again.
    func testATerminateWhoseClearFailsThreeTimesExitsNonZeroAndSavesTheFailure() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.setTakes = false }
        await service.terminate(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "set 0", "read", "set 0", "read"])
        XCTAssertEqual(fake.with { $0.pauses }, [2, 2])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .stopped))
        XCTAssertEqual(stateFile.loadFailure(), .readBack(expected: false))
        XCTAssertEqual(fake.with { $0.terminations }, [1])
    }

    func testATerminateWhoseClearTakesOnTheSecondTryExitsZero() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.failSetsRemaining = 1 }
        await service.terminate(now: t0 + 60)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "set 0", "read"])
        XCTAssertEqual(fake.with { $0.pauses }, [2])
        XCTAssertNil(stateFile.loadFailure())
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    func testATerminateWhileIdleJustExits() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.terminate(now: t0)
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    func testATerminateWithAClearStillOwedTriesItOnceMore() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.setStatus = 1 }
        _ = await service.tick(now: t0 + 120)
        fake.with { $0.calls = []; $0.setStatus = 0 }
        await service.terminate(now: t0 + 130)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read"])
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    // MARK: - Fix round 1: Apply and the floor switch read the battery afresh (§ Behaviour,
    // Battery floor: "on battery and below 25 %"; a missed notification must not end them)

    func testAStaleLowReadingCannotEndAnApplyMadeOnTheCharger() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        _ = await service.powerChanged(now: t0)
        fake.with { $0.power = KeepAwakePower(onBattery: false, percent: 10); $0.calls = [] }
        let reply = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 60)
        XCTAssertEqual(reply, KeepAwakeReply(state: .armed(deadline: t0 + 7_260, floorEnabled: true), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 1", "read"])
    }

    func testAStaleLowReadingCannotEndTheModeWhenTheFloorIsTurnedOnOnTheCharger() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: false, now: t0)
        fake.with { $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        _ = await service.powerChanged(now: t0 + 60)
        fake.with { $0.power = KeepAwakePower(onBattery: false, percent: 10); $0.calls = [] }
        let reply = await service.setFloor(enabled: true, now: t0 + 120)
        XCTAssertEqual(reply, KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, [], "the flag is already on")
    }

    /// The fresh reading can still end the mode: low on battery, the floor on, the lid closed.
    func testAnApplyBelowTheFloorOnBatteryEndsTheOldModeAndSleepsAClosedMac() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        _ = await service.arm(seconds: 7_200, floorEnabled: false, now: t0)
        fake.with { $0.calls = []; $0.lid = KeepAwakeLid(closed: true, causesSleep: true); $0.power = KeepAwakePower(onBattery: true, percent: 10) }
        let reply = await service.arm(seconds: 3_600, floorEnabled: true, now: t0 + 60)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 60, reason: .batteryFloor), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    // MARK: - Fix round 4: connections carry an id, so an open and a close may land in any order

    /// The listener reports both from unordered tasks. A close that lands before its open is a
    /// connection already gone: once the late open lands, nothing holds the daemon.
    func testAConnectionWhoseCloseLandsFirstHoldsNothingOnceItsOpenLands() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.connectionClosed(id: 7, now: t0 + 1)
        XCTAssertEqual(fake.with { $0.exits }, [t0 + 61])
        await service.connectionOpened(id: 7, now: t0 + 2)
        XCTAssertEqual(fake.with { $0.exits }, [t0 + 61, t0 + 62])
        await service.exitIfIdle(now: t0 + 62)
        XCTAssertEqual(fake.with { $0.terminations }, [0])
    }

    /// The early close is remembered once: the same id opening again later is a new, live
    /// connection and holds the daemon.
    func testAnEarlyCloseCancelsOnlyItsOwnOpen() async {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        await service.connectionClosed(id: 3, now: t0)
        await service.connectionOpened(id: 3, now: t0 + 1)
        await service.connectionOpened(id: 4, now: t0 + 2)
        await service.connectionOpened(id: 3, now: t0 + 3)
        await service.connectionClosed(id: 4, now: t0 + 4)
        XCTAssertEqual(fake.with { $0.exits }.last ?? nil, nil, "connection 3 is open")
        await service.exitIfIdle(now: t0 + 3_600)
        XCTAssertEqual(fake.with { $0.terminations }, [])
        await service.connectionClosed(id: 3, now: t0 + 5)
        XCTAssertEqual(fake.with { $0.exits }.last ?? nil, t0 + 65)
    }
}
