import XCTest
import ObjectiveC
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Settings ("A change while armed reaches the
/// daemon at once, like `setFloor`"), § Daemon (the XPC contract stays readable both ways) and
/// § Plan decisions accepted by the session, items 6 and 9: the switch is a selector of its own
/// beside 4.3.0's four, which keep their names; it sets the helper's guard and feeds it no
/// reading, in any state.
final class KeepAwakeThermalGuardXPCTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeThermalGuardXPCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("keepawake.json") }
    private var stateFile: KeepAwakeStateFile { KeepAwakeStateFile(url: fileURL) }
    private var stillArmed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }
    private let lidClosed = KeepAwakeLid(closed: true, causesSleep: true)

    /// Past its start at t0, the start's calls forgotten.
    private func started(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    /// Armed for two hours at t0 with the lid open, the start's and the arm's calls forgotten.
    private func armed(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    /// Removes the state file, so that any write after this shows as a file.
    private func forgetTheFile() throws {
        try FileManager.default.removeItem(at: fileURL)
    }

    private var fileWasWritten: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: - The contract

    func testTodaysSelectorsKeepTheirNamesAndTheGuardHasItsOwn() {
        XCTAssertEqual(NSStringFromProtocol(KeepAwakeXPCProtocol.self), "OMKeepAwakeXPCProtocol")
        XCTAssertEqual(NSStringFromSelector(#selector(KeepAwakeXPCProtocol.arm(seconds:floorEnabled:withReply:))), "armWithSeconds:floorEnabled:withReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(KeepAwakeXPCProtocol.disarm(withReply:))), "disarmWithReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(KeepAwakeXPCProtocol.setFloor(enabled:withReply:))), "setFloorWithEnabled:withReply:")
        XCTAssertEqual(NSStringFromSelector(#selector(KeepAwakeXPCProtocol.state(withReply:))), "stateWithReply:")
        XCTAssertEqual(
            NSStringFromSelector(#selector(KeepAwakeXPCProtocol.setThermalGuard(enabled:withReply:))),
            "setThermalGuardWithEnabled:withReply:"
        )
    }

    /// What `NSXPCInterface(with:)` reads on both ends is the protocol as the Objective-C runtime
    /// holds it: its required instance methods are 4.3.0's four and the guard's, nothing else,
    /// and none of them optional.
    func testTheRuntimeListsFourSelectorsOf430AndTheGuardsOnTheProtocol() {
        func selectors(required: Bool) -> [String] {
            var count: UInt32 = 0
            let list = protocol_copyMethodDescriptionList(KeepAwakeXPCProtocol.self, required, true, &count)
            defer { free(list) }
            return (0..<Int(count)).compactMap { list?[$0].name }.map(NSStringFromSelector).sorted()
        }
        XCTAssertEqual(selectors(required: true), [
            "armWithSeconds:floorEnabled:withReply:",
            "disarmWithReply:",
            "setFloorWithEnabled:withReply:",
            "setThermalGuardWithEnabled:withReply:",
            "stateWithReply:",
        ])
        XCTAssertEqual(selectors(required: false), [])
    }

    // MARK: - The switch in the service

    func testTheSwitchReachesTheServiceAndTheReplySaysSo() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        let reply = await service.setThermalGuard(enabled: false, now: t0 + 60)
        XCTAssertEqual(
            reply,
            KeepAwakeReply(state: stillArmed, failure: nil, thermal: .nominal, thermalGuard: false)
        )
        XCTAssertEqual(fake.with { $0.calls }, [], "the flag is already on")
        fake.with { $0.lid = lidClosed; $0.thermal = .critical }
        let tick = await service.tick(now: t0 + 120)
        XCTAssertEqual(tick.state, stillArmed)
    }

    /// Turning the guard back on ends nothing by itself; the next reading decides.
    func testTurningTheGuardBackOnLetsTheNextReadingDecide() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        _ = await service.setThermalGuard(enabled: false, now: t0 + 60)
        fake.with { $0.lid = lidClosed; $0.thermal = .critical }
        let on = await service.setThermalGuard(enabled: true, now: t0 + 90)
        XCTAssertEqual(on.state, stillArmed, "the switch itself ends nothing")
        XCTAssertEqual(on.thermalGuard, true)
        let tick = await service.tick(now: t0 + 120)
        XCTAssertEqual(tick.state, .ended(at: t0 + 120, reason: .overheated))
    }

    /// While a mode is armed the switch is the guard's and nothing else's: no pmset, the flag as
    /// it was, nothing written, and the tick pending since the Apply where it was (§ Plan
    /// decisions accepted by the session, item 2a).
    func testTheSwitchWhileArmedRunsNoPmsetAndWritesNoFile() async throws {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        try forgetTheFile()
        let off = await service.setThermalGuard(enabled: false, now: t0 + 60)
        let on = await service.setThermalGuard(enabled: true, now: t0 + 90)
        XCTAssertEqual(off, KeepAwakeReply(state: stillArmed, failure: nil, thermal: .nominal, thermalGuard: false))
        XCTAssertEqual(on, KeepAwakeReply(state: stillArmed, failure: nil, thermal: .nominal, thermalGuard: true))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.flag }, .set)
        XCTAssertFalse(fileWasWritten)
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 60, t0 + 60])
    }

    /// With nothing armed the helper still takes the switch (its reply says so) and touches
    /// neither the flag nor the file; the mode stays idle, or ended as it ended.
    func testTheSwitchWhileIdleOrEndedChangesOnlyTheGuard() async throws {
        let fake = FakeKeepAwakeMachine()
        let service = await started(fake)
        try forgetTheFile()
        let idle = await service.setThermalGuard(enabled: false, now: t0 + 10)
        XCTAssertEqual(idle, KeepAwakeReply(state: .idle, failure: nil, thermal: .nominal, thermalGuard: false))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertFalse(fileWasWritten)
        XCTAssertEqual(fake.with { $0.scheduled }, [nil], "no tick while nothing is armed")

        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0 + 20)
        _ = await service.disarm(now: t0 + 30)
        fake.with { $0.calls = [] }
        try forgetTheFile()
        let ended = await service.setThermalGuard(enabled: false, now: t0 + 40)
        XCTAssertEqual(
            ended,
            KeepAwakeReply(state: .ended(at: t0 + 30, reason: .cancelled), failure: nil, thermal: .nominal, thermalGuard: false)
        )
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
        XCTAssertFalse(fileWasWritten)
    }

    /// A flag another tool set, which the start left alone, is not the switch's to clear either.
    func testTheSwitchLeavesAFlagAnotherToolSetAsItIs() async throws {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.flag = .set }
        let service = await started(fake)
        try forgetTheFile()
        _ = await service.setThermalGuard(enabled: false, now: t0 + 10)
        _ = await service.setThermalGuard(enabled: true, now: t0 + 20)
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.flag }, .set)
        XCTAssertFalse(fileWasWritten)
    }

    /// Off while a hot minute is being counted forgets it: back on, the minute starts at the
    /// next reading. The tick pending stays where it was (§ Plan decisions accepted by the
    /// session, item 2a); it no longer finds a minute that is up.
    func testTurningTheGuardOffForgetsTheHotMinuteBeingCounted() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = lidClosed; $0.thermal = .serious }
        _ = await service.tick(now: t0 + 60)
        _ = await service.state(now: t0 + 65)
        _ = await service.setThermalGuard(enabled: false, now: t0 + 70)
        _ = await service.setThermalGuard(enabled: true, now: t0 + 80)
        XCTAssertEqual(
            fake.with { $0.scheduled },
            [t0 + 120, t0 + 120, t0 + 120, t0 + 120],
            "neither the poll nor the switch moves the tick the reading at 60 set"
        )
        let first = await service.tick(now: t0 + 120)
        XCTAssertEqual(first.state, stillArmed, "a minute from 60 would have ended it here")
        XCTAssertEqual(fake.with { $0.calls }, [])
        let second = await service.tick(now: t0 + 180)
        XCTAssertEqual(second.state, .ended(at: t0 + 180, reason: .overheated))
    }

    /// The switch is an input like the others in one respect: a mode whose deadline has passed
    /// ends for the deadline when it arrives, the flag cleared and, the lid being closed, slept.
    func testASwitchThatArrivesAfterTheDeadlineEndsTheModeForTheDeadline() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = lidClosed }
        let reply = await service.setThermalGuard(enabled: false, now: t0 + 7_260)
        XCTAssertEqual(
            reply,
            KeepAwakeReply(state: .ended(at: t0 + 7_200, reason: .deadline), failure: nil, thermal: .nominal, thermalGuard: false)
        )
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 7_200, reason: .deadline))
    }
}
