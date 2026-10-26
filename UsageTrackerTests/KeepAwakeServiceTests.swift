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
    }
    private let lock = NSLock()
    private var storage = Storage()

    func with<T>(_ body: (inout Storage) -> T) -> T { lock.withLock { body(&storage) } }

    func machine() -> KeepAwakeMachine {
        KeepAwakeMachine(
            setSleepDisabled: { value in
                self.with { s in
                    s.calls.append("set \(value ? 1 : 0)")
                    if s.setStatus == 0, s.setTakes { s.flag = value ? .set : .cleared }
                    return KeepAwakeCommandResult(status: s.setStatus, output: "")
                }
            },
            readSleepDisabled: { self.with { s in s.calls.append("read"); return s.flag } },
            sleepNow: { self.with { s in s.calls.append("sleepnow"); return KeepAwakeCommandResult(status: s.sleepStatus, output: "") } },
            lid: { self.with { $0.lid } },
            power: { self.with { $0.power } },
            schedule: { date in self.with { $0.scheduled.append(date) } }
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
        fake.with { $0.calls = []; $0.scheduled = [] }
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
}
