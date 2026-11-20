import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Daemon ("The daemon reads the thermal state
/// itself, as it reads the battery: on the change notification and on its one-minute tick. The
/// app quitting changes nothing") and § Rule ("Ending follows the existing path: the flag is
/// cleared and, the lid being closed, `pmset sleepnow` runs").
final class KeepAwakeHeatServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeHeatServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    /// Armed for two hours at t0 with the lid open, the start's and the arm's calls forgotten.
    private func armed(_ fake: FakeKeepAwakeMachine) async -> KeepAwakeService {
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        _ = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        fake.with { $0.calls = []; $0.scheduled = []; $0.exits = [] }
        return service
    }

    private var stillArmed: KeepAwakeState { .armed(deadline: t0 + 7_200, floorEnabled: true) }

    func testACriticalTickWithTheLidClosedClearsTheFlagAndSleeps() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true); $0.thermal = .critical }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply, KeepAwakeReply(state: .ended(at: t0 + 60, reason: .overheated), failure: nil, thermal: .critical, thermalGuard: true))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
        XCTAssertEqual(fake.with { $0.flag }, .cleared)
        XCTAssertEqual(fake.with { $0.scheduled }, [nil])
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .overheated))
    }

    func testSeriousOnTwoTicksAMinuteApartEndsTheMode() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true); $0.thermal = .serious }
        let first = await service.tick(now: t0 + 60)
        XCTAssertEqual(first.state, stillArmed)
        XCTAssertEqual(fake.with { $0.calls }, [], "one hot reading ends nothing")
        let second = await service.tick(now: t0 + 120)
        XCTAssertEqual(second.state, .ended(at: t0 + 120, reason: .overheated))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    /// The change notification is a reading too, and the minute it starts sets the next tick,
    /// whatever input comes in between.
    func testAThermalNotificationIsAReadingAndBringsTheTickForward() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true); $0.thermal = .serious }
        _ = await service.thermalChanged(now: t0 + 30)
        _ = await service.state(now: t0 + 50)
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 90, t0 + 90], "the minute is up at 90, not a minute after the poll")
        let reply = await service.tick(now: t0 + 90)
        XCTAssertEqual(reply.state, .ended(at: t0 + 90, reason: .overheated))
    }

    /// Spec § Plan decisions accepted by the session, item 2: no reading comes when the lid
    /// closes (there is no lid observer, and closing it changes no level); while armed the next
    /// tick is never more than a minute away, so a Mac already critical ends within a minute of
    /// the lid closing.
    func testACriticalMacEndsAtTheFirstReadingAfterTheLidClosesWithinAMinute() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.thermal = .critical }
        let open = await service.tick(now: t0 + 30)
        XCTAssertEqual(open.state, stillArmed, "lid open: nothing ends")
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 90], "the next reading is a minute away at most")
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }   // closed just after t0 + 30; nothing reads
        let reply = await service.tick(now: t0 + 90)
        XCTAssertEqual(reply.state, .ended(at: t0 + 90, reason: .overheated), "stamped at the reading, not at the close")
    }

    /// At serious the minute starts at that first closed-lid reading: within two minutes of the
    /// lid closing.
    func testASeriousMacEndsWithinTwoMinutesOfTheLidClosing() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.thermal = .serious }
        _ = await service.tick(now: t0 + 30)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true) }   // closed just after t0 + 30
        let first = await service.tick(now: t0 + 90)
        XCTAssertEqual(first.state, stillArmed, "the run starts at the first closed-lid reading")
        XCTAssertEqual(fake.with { $0.scheduled }, [t0 + 90, t0 + 150])
        let second = await service.tick(now: t0 + 150)
        XCTAssertEqual(second.state, .ended(at: t0 + 150, reason: .overheated))
    }

    func testACriticalNotificationEndsTheModeAtThatReading() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: true); $0.thermal = .critical }
        let reply = await service.thermalChanged(now: t0 + 30)
        XCTAssertEqual(reply.state, .ended(at: t0 + 30, reason: .overheated))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    /// § Rule: "With the lid open the guard ends nothing"; the reply still says how hot it is.
    func testWithTheLidOpenTheHeatOnlyShowsInTheReply() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.thermal = .critical }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply, KeepAwakeReply(state: stillArmed, failure: nil, thermal: .critical, thermalGuard: true))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.flag }, .set)
    }

    /// A closed lid on an external display (clamshell mode) reads `AppleClamshellCausesSleep` No
    /// and counts as open, as for the sleep at the end (keep-awake plan D5): the Mac is in use.
    func testInClamshellModeOnAnExternalDisplayHeatEndsNothing() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with { $0.lid = KeepAwakeLid(closed: true, causesSleep: false); $0.thermal = .critical }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, stillArmed)
    }

    /// One tick reads the battery before the heat: below the floor and critical, the mode ends
    /// for the battery, once, with one sleep.
    func testATickReadsTheBatteryFirst() async {
        let fake = FakeKeepAwakeMachine()
        let service = await armed(fake)
        fake.with {
            $0.lid = KeepAwakeLid(closed: true, causesSleep: true)
            $0.thermal = .critical
            $0.power = KeepAwakePower(onBattery: true, percent: 10)
        }
        let reply = await service.tick(now: t0 + 60)
        XCTAssertEqual(reply.state, .ended(at: t0 + 60, reason: .batteryFloor))
        XCTAssertEqual(fake.with { $0.calls }, ["set 0", "read", "sleepnow"])
    }

    /// A notification while nothing is armed feeds the engine nothing and moves no timer, so a
    /// level that keeps changing never holds an idle helper past its idle exit; the reply still
    /// carries the level.
    func testANotificationWhileNotArmedChangesNothing() async {
        let fake = FakeKeepAwakeMachine()
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        fake.with {
            $0.calls = []; $0.scheduled = []; $0.exits = []
            $0.thermal = .critical
            $0.lid = KeepAwakeLid(closed: true, causesSleep: true)
        }
        let reply = await service.thermalChanged(now: t0 + 30)
        XCTAssertEqual(reply, KeepAwakeReply(state: .idle, failure: nil, thermal: .critical, thermalGuard: true))
        XCTAssertEqual(fake.with { $0.calls }, [])
        XCTAssertEqual(fake.with { $0.scheduled }, [])
        XCTAssertEqual(fake.with { $0.exits }, [])
    }
}
