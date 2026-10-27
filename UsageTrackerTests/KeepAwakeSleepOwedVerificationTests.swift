import XCTest
import ServiceManagement
@testable import Omelette

/// Verifier tests for the two keep-awake fixes after the whole-branch review (spec 2026-10-26,
/// § Design › Behaviour and › the helper): W1, a sleep the helper still owes (review C4) is
/// kept in the state file and paid or dropped by the next start; W3, a floor switched while
/// Apply was out reaches an armed helper.
final class KeepAwakeSleepOwedVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeSleepOwedVerificationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private let lidClosed = KeepAwakeLid(closed: true, causesSleep: true)
    private let lidOpen = KeepAwakeLid(closed: false, causesSleep: true)

    // MARK: - W1: the state file

    /// A file that says "nothing owed" in any spelling, or says something that is not a Bool,
    /// owes nothing.
    func testAFileWhoseOwedFieldIsFalseNullOrGarbageOwesNothing() throws {
        let ended = KeepAwakeState.ended(at: t0, reason: .deadline)
        try stateFile.save(ended, sleepOwed: true)
        let owing = try String(contentsOf: stateFile.url, encoding: .utf8)
        for spelling in [#""sleepOwed":false"#, #""sleepOwed":null"#, #""sleepOwed":"yes""#, #""sleepOwed":1"#, #""sleepOwed":{}"#] {
            let rewritten = owing.replacingOccurrences(of: #""sleepOwed":true"#, with: spelling)
            XCTAssertNotEqual(rewritten, owing, "the fixture has the field: \(owing)")
            try Data(rewritten.utf8).write(to: stateFile.url)
            XCTAssertFalse(stateFile.loadSleepOwed(), spelling)
        }
    }

    /// A debt in a file of another version is not read (the whole file reads as nothing).
    func testADebtInAFileOfAnotherVersionIsNotOwed() throws {
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true)
        let owing = try String(contentsOf: stateFile.url, encoding: .utf8)
        try Data(owing.replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8).write(to: stateFile.url)
        XCTAssertFalse(stateFile.loadSleepOwed())
        XCTAssertNil(stateFile.load())
    }

    func testANoFileOwesNothing() {
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    // MARK: - W1: start

    /// The crash came after the debt was written but before the clear: the flag still reads SET
    /// at the restart, the lid is closed, and the engine's own bag rule (C5) also asks for a
    /// sleep. One debt and one rule, one `pmset sleepnow`.
    func testADebtAndASetFlagWithTheLidClosedSleepOnceNotTwice() async throws {
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set; $0.lid = lidClosed }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0 + 150)
        XCTAssertEqual(reply.failure, nil)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    /// The restart case: the persisted state is `.armed` (the daemon died mid-mode) and a debt
    /// rides with it. The mode ends as restarted, the clear takes, the sleep runs once.
    func testADebtRestoredBesideAnArmedStateEndsTheModeAndSleepsOnce() async throws {
        try stateFile.save(.armed(deadline: t0 + 3_600, floorEnabled: true), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .cleared; $0.lid = lidClosed }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0 + 150)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 150, reason: .restarted), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadSleepOwed())
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 150, reason: .restarted))
    }

    /// The same debt beside an armed state, lid open: dropped, no sleep.
    func testADebtRestoredBesideAnArmedStateWithTheLidOpenIsDropped() async throws {
        try stateFile.save(.armed(deadline: t0 + 3_600, floorEnabled: true), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .cleared; $0.lid = lidOpen }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0 + 150)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read"])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    /// `pmset sleepnow` fails again at the restart: the debt stays in the file, the retry tick is
    /// scheduled, the daemon does not go idle, and a third daemon still pays it.
    func testASleepThatFailsAgainAtARestartStaysOwedOnDiskAndRetries() async throws {
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = lidClosed; $0.sleepStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0 + 150)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0, reason: .deadline), failure: nil))
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertTrue(stateFile.loadSleepOwed(), "still owed on disk")
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 210], "the retry tick")
        XCTAssertEqual(fake.with { $0.exits }, [nil], "owed: not idle")

        // The retry succeeds on the next tick.
        fake.with { $0.calls = []; $0.sleepStatus = 0 }
        _ = await service.tick(now: t0 + 210)
        XCTAssertEqual(fake.with { $0.calls }, ["sleepnow"])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    func testASleepThatFailsAtTwoRestartsInARowIsPaidByTheThird() async throws {
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = lidClosed; $0.sleepStatus = 1 }
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0 + 150)
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0 + 300)
        XCTAssertTrue(stateFile.loadSleepOwed())
        fake.with { $0.calls = []; $0.sleepStatus = 0 }
        _ = await KeepAwakeService(machine: fake.machine(), stateFile: stateFile).start(now: t0 + 450)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    /// The clear fails at the restart: sleepnow never runs before the clear reads back (rule 5),
    /// and the debt stays on disk for the retry.
    func testARestartWhoseClearFailsKeepsTheDebtAndDoesNotSleepYet() async throws {
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true)
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = lidClosed; $0.setStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let reply = await service.start(now: t0 + 150)
        XCTAssertNotNil(reply.failure)
        XCTAssertEqual(fake.with { $0.calls }, ["read", "set 0"])
        XCTAssertTrue(stateFile.loadSleepOwed())
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 210])
        fake.with { $0.calls = []; $0.setStatus = 0 }
        _ = await service.tick(now: t0 + 210)
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    // MARK: - W1: ticks, idle exit and terminate while owing

    /// A service that owes a sleep whose `pmset sleepnow` keeps failing.
    private func owing(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        fake.with { $0.lid = lidClosed; $0.sleepStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        _ = await service.tick(now: t0 + 120)
        XCTAssertTrue(stateFile.loadSleepOwed())
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    /// Rule 9: a debt keeps the daemon alive, whoever connects and disconnects.
    func testTheIdleExitNeverFiresWhileASleepIsOwed() async {
        let fake = FakeKeepAwakeMachine()
        let service = await owing(fake)
        await service.connectionOpened(id: 1, now: t0 + 130)
        await service.connectionClosed(id: 1, now: t0 + 140)
        await service.exitIfIdle(now: t0 + 10_000)
        XCTAssertEqual(fake.with { $0.exits }, [nil, nil])
        XCTAssertEqual(fake.with { $0.terminations }, [])
    }

    /// The lid opens before the retry: the tick drops the debt and the file loses it, with the
    /// state unchanged.
    func testAnOwedSleepDroppedByALidOpenedOnATickLeavesTheFile() async {
        let fake = FakeKeepAwakeMachine()
        let service = await owing(fake)
        fake.with { $0.lid = lidOpen }
        _ = await service.tick(now: t0 + 180)
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    /// Rule 10 with a clear that never takes: the stop saves the failure and not the debt, and
    /// the daemon exits 1.
    func testATerminateWhoseClearFailsStillDropsTheDebtFromTheFile() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.lid = lidClosed; $0.sleepStatus = 1 }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 120, floorEnabled: true, now: t0)
        fake.with { $0.setStatus = 1 }
        _ = await service.tick(now: t0 + 120)
        XCTAssertTrue(stateFile.loadSleepOwed(), "owed, and unpaid because the clear failed")
        fake.with { $0.calls = [] }
        await service.terminate(now: t0 + 130)
        XCTAssertEqual(fake.with { $0.terminations }, [1])
        XCTAssertFalse(fake.with { $0.calls }.contains("sleepnow"))
        XCTAssertFalse(stateFile.loadSleepOwed())
        XCTAssertNotNil(stateFile.loadFailure())
    }

    // MARK: - W3: the floor correction

    private actor RequestLog {
        private(set) var requests: [KeepAwakeRequest] = []
        func append(_ request: KeepAwakeRequest) { requests.append(request) }
    }

    @MainActor private final class FloorSwitch {
        var enabled = false
    }

    /// A reply held until the test releases it.
    private actor Held {
        private var waiter: CheckedContinuation<Result<KeepAwakeReply, KeepAwakeFailure>, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var asked = false

        func reply() async -> Result<KeepAwakeReply, KeepAwakeFailure> {
            asked = true
            arrival?.resume()
            arrival = nil
            return await withCheckedContinuation { waiter = $0 }
        }

        func untilAsked() async {
            if asked { return }
            await withCheckedContinuation { arrival = $0 }
        }

        func release(_ result: Result<KeepAwakeReply, KeepAwakeFailure>) {
            waiter?.resume(returning: result)
            waiter = nil
        }
    }

    @MainActor private func makeModel(
        floor: FloorSwitch,
        send: @escaping @Sendable (KeepAwakeRequest) async -> Result<KeepAwakeReply, KeepAwakeFailure>
    ) -> KeepAwakeModel {
        var dependencies = KeepAwakeFakeHelper(statuses: [.enabled]).dependencies()
        dependencies.send = send
        return KeepAwakeModel(
            client: KeepAwakeClient(dependencies: dependencies),
            floorEnabled: { floor.enabled },
            rememberDuration: { _ in },
            resetSettings: {}
        )
    }

    /// Runs one Apply with the floor setting off, flips it on while the arm is out, and releases
    /// the arm's reply; returns after Apply finished.
    @MainActor private func applyWithTheFloorFlipped(
        model: KeepAwakeModel, floor: FloorSwitch, arm: Held, release: Result<KeepAwakeReply, KeepAwakeFailure>
    ) async {
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await arm.untilAsked()
        floor.enabled = true
        await model.floorChanged(true, now: t0)
        await arm.release(release)
        await applying.value
    }

    /// The arm failed in transit: the helper may or may not be armed, so Apply sends nothing more
    /// and the model reconciles by asking.
    @MainActor func testAnArmWhoseReplyIsLostSendsNoFloorCorrection() async {
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            if case .arm = request { return await arm.reply() }
            return .failure(.helperTimedOut)
        }
        await applyWithTheFloorFlipped(model: model, floor: floor, arm: arm, release: .failure(.helperTimedOut))
        let requests = await log.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: false)])
        XCTAssertTrue(model.needsReconcile)
        XCTAssertEqual(model.failure, .helperTimedOut)
        XCTAssertFalse(model.isWorking)
    }

    /// The helper answered the arm with an error and an idle state: nothing is armed to correct.
    @MainActor func testAnArmTheHelperRefusedSendsNoFloorCorrection() async {
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            if case .arm = request { return await arm.reply() }
            return answer(.idle)
        }
        let refusal = Result<KeepAwakeReply, KeepAwakeFailure>.success(
            KeepAwakeReply(state: .idle, failure: .readBack(expected: true))
        )
        await applyWithTheFloorFlipped(model: model, floor: floor, arm: arm, release: refusal)
        let requests = await log.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: false)])
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.failure, .readBack(expected: true))
    }

    /// The correction's own reply is lost: the armed state stays on screen, the loss is shown and
    /// the poll keeps asking until the helper answers.
    @MainActor func testACorrectionWhoseReplyTimesOutLeavesTheModelToReconcile() async {
        let t0 = self.t0
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            switch request {
            case .arm: return await arm.reply()
            case .setFloor: return .failure(.helperTimedOut)
            case .state: return .success(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
            case .disarm: return .success(KeepAwakeReply(state: .idle, failure: nil))
            }
        }
        await applyWithTheFloorFlipped(model: model, floor: floor, arm: arm, release: answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        var requests = await log.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: false), .setFloor(enabled: true)])
        XCTAssertTrue(model.needsReconcile)
        XCTAssertEqual(model.failure, .helperTimedOut)
        XCTAssertTrue(model.state.isArmed)
        XCTAssertFalse(model.isWorking)
        await model.pollIfNeeded(now: t0 + 60)
        requests = await log.requests
        XCTAssertEqual(requests.last, .state)
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        XCTAssertFalse(model.needsReconcile)
    }

    /// A Cancel landed after the arm, before the correction: the arm's reply says armed, the
    /// correction goes to a helper that is idle, and the helper's last word is what the model
    /// shows.
    @MainActor func testACancelThatLandedBeforeTheCorrectionLeavesTheHelpersLastWord() async {
        let t0 = self.t0
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let cancelled = KeepAwakeState.ended(at: t0 + 30, reason: .cancelled)
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            switch request {
            case .arm: return await arm.reply()
            case .disarm, .setFloor: return answer(cancelled)
            case .state: return answer(cancelled)
            }
        }
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await arm.untilAsked()
        floor.enabled = true
        await model.cancel(now: t0 + 30)
        await arm.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        await applying.value
        let requests = await log.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: false), .disarm, .setFloor(enabled: true)])
        XCTAssertEqual(model.state, cancelled)
        XCTAssertFalse(model.isWorking)
    }

    /// After a correction the model is armed like any other: the floor switch still reaches the
    /// helper at once.
    @MainActor func testTheFloorSwitchStillWorksAfterACorrection() async {
        let t0 = self.t0
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            switch request {
            case .arm: return await arm.reply()
            case .setFloor(let enabled): return answer(.armed(deadline: t0 + 7_200, floorEnabled: enabled))
            case .state, .disarm: return answer(.idle)
            }
        }
        await applyWithTheFloorFlipped(model: model, floor: floor, arm: arm, release: answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
        floor.enabled = false
        await model.floorChanged(false, now: t0 + 60)
        let requests = await log.requests
        XCTAssertEqual(requests.last, .setFloor(enabled: false))
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: false))
    }

    /// A state request that started while the correction was out is older than the correction's
    /// reply, and is dropped when it lands last.
    @MainActor func testAPollThatStartedDuringTheCorrectionDoesNotUndoIt() async {
        let t0 = self.t0
        let arm = Held()
        let correction = Held()
        let poll = Held()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            switch request {
            case .arm: return await arm.reply()
            case .setFloor: return await correction.reply()
            case .state: return await poll.reply()
            case .disarm: return answer(.idle)
            }
        }
        let applying = Task { await model.arm(days: 0, hours: 2, minutes: 0, now: t0) }
        await arm.untilAsked()
        floor.enabled = true
        await arm.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        await correction.untilAsked()
        let polling = Task { await model.pollIfNeeded(now: t0 + 10) }
        await poll.untilAsked()
        await correction.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        await applying.value
        await poll.release(answer(.armed(deadline: t0 + 7_200, floorEnabled: false)))
        await polling.value
        XCTAssertEqual(model.state, .armed(deadline: t0 + 7_200, floorEnabled: true))
    }

    /// The comparison is with the floor Apply sent, not with the floor the reply reports: a reply
    /// that reports the setting's present value while Apply sent the old one still gets the
    /// setting sent on (spec: "differs from the one Apply sent"). Only reachable with a reply
    /// that does not echo the request.
    @MainActor func testTheCorrectionComparesWithTheFloorApplySentNotTheRepliesFloor() async {
        let t0 = self.t0
        let arm = Held()
        let log = RequestLog()
        let floor = FloorSwitch()
        let model = makeModel(floor: floor) { request in
            await log.append(request)
            switch request {
            case .arm: return await arm.reply()
            case .setFloor(let enabled): return answer(.armed(deadline: t0 + 7_200, floorEnabled: enabled))
            case .state, .disarm: return answer(.idle)
            }
        }
        await applyWithTheFloorFlipped(model: model, floor: floor, arm: arm, release: answer(.armed(deadline: t0 + 7_200, floorEnabled: true)))
        let requests = await log.requests
        XCTAssertEqual(requests, [.arm(seconds: 7_200, floorEnabled: false), .setFloor(enabled: true)])
    }
}

/// The helper's answer: a state, no failure.
private func answer(_ state: KeepAwakeState) -> Result<KeepAwakeReply, KeepAwakeFailure> {
    .success(KeepAwakeReply(state: state, failure: nil))
}
