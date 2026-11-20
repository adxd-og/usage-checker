import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Daemon: "The state the daemon reports gains the
/// end reason and the last thermal level", readable across an update both ways; § Plan decisions
/// accepted by the session, items 5 and 7. Every reply carries the level as the helper read it
/// when answering and whether its guard is on; a reply without them is a helper that predates
/// the guard.
final class KeepAwakeThermalReplyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeThermalReplyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private func reply(_ json: String) -> KeepAwakeReply? {
        KeepAwakeCoding.decode(KeepAwakeReply.self, from: Data(json.utf8))
    }

    private func text(_ reply: KeepAwakeReply) -> String {
        String(decoding: KeepAwakeCoding.encode(reply), as: UTF8.self)
    }

    func testEveryReplyCarriesTheLevelAsReadAndTheGuard() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.thermal = .fair }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        let started = await service.start(now: t0)
        XCTAssertEqual(started, KeepAwakeReply(state: .idle, failure: nil, thermal: .fair, thermalGuard: true))
        let armed = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(
            armed,
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermal: .fair, thermalGuard: true)
        )
        fake.with { $0.thermal = .serious }
        let polled = await service.state(now: t0 + 60)
        XCTAssertEqual(
            polled,
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermal: .serious, thermalGuard: true),
            "read when answering, not at the start"
        )
        fake.with { $0.thermal = .critical }
        let floorOff = await service.setFloor(enabled: false, now: t0 + 90)
        XCTAssertEqual(
            floorOff,
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: false), failure: nil, thermal: .critical, thermalGuard: true)
        )
        fake.with { $0.thermal = .nominal; $0.power = KeepAwakePower(onBattery: false, percent: 80) }
        let onPower = await service.powerChanged(now: t0 + 100)
        XCTAssertEqual(
            onPower,
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: false), failure: nil, thermal: .nominal, thermalGuard: true)
        )
        fake.with { $0.thermal = .fair }
        let cancelled = await service.disarm(now: t0 + 120)
        XCTAssertEqual(
            cancelled,
            KeepAwakeReply(state: .ended(at: t0 + 120, reason: .cancelled), failure: nil, thermal: .fair, thermalGuard: true)
        )
    }

    /// The replies that leave the service before or beside its last step: a refused duration
    /// (rule 1's early return), a set pmset refuses (rule 8 with its failure) and a power
    /// notification on a Mac without a battery. They carry the level and the guard like any other.
    func testRepliesThatEndEarlyOrFailStillCarryTheLevelAndTheGuard() async {
        let fake = FakeKeepAwakeMachine()
        fake.with { $0.thermal = .serious }
        let service = KeepAwakeService(machine: fake.machine(), stateFile: stateFile)
        _ = await service.start(now: t0)
        let refused = await service.arm(seconds: 30, floorEnabled: true, now: t0)
        XCTAssertEqual(refused, KeepAwakeReply(state: .idle, failure: .invalidDuration, thermal: .serious, thermalGuard: true))
        fake.with { $0.setStatus = 1 }
        let failed = await service.arm(seconds: 7_200, floorEnabled: true, now: t0)
        XCTAssertEqual(
            failed,
            KeepAwakeReply(state: .idle, failure: .commandFailed(command: "pmset", status: 1), thermal: .serious, thermalGuard: true)
        )
        let noBattery = await service.powerChanged(now: t0 + 60)
        XCTAssertEqual(noBattery, KeepAwakeReply(state: .idle, failure: nil, thermal: .serious, thermalGuard: true))
    }

    /// A 4.3.0 helper answers without the two keys, with a failure or without one: nothing to
    /// read, nothing new to ask it.
    func testAReplyWithoutTheKeysComesFromAHelperBeforeTheGuard() {
        let old = reply(#"{"state":{"armed":{"deadline":1793007200,"floorEnabled":true}}}"#)
        XCTAssertEqual(old, KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil))
        XCTAssertNotNil(old)
        XCTAssertNil(old?.thermal)
        XCTAssertNil(old?.thermalGuard)
        let failed = reply(#"{"failure":{"commandFailed":{"command":"pmset","status":1}},"state":{"ended":{"at":1793000120,"reason":"deadline"}}}"#)
        XCTAssertEqual(
            failed,
            KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: .commandFailed(command: "pmset", status: 1))
        )
        XCTAssertNotNil(failed)
        XCTAssertNil(failed?.thermal)
        XCTAssertNil(failed?.thermalGuard)
    }

    func testTheTwoKeysAreWrittenBesideTheState() {
        XCTAssertEqual(
            text(KeepAwakeReply(state: .idle, failure: nil, thermal: .serious, thermalGuard: false)),
            #"{"state":{"idle":{}},"thermal":"serious","thermalGuard":false}"#
        )
        XCTAssertEqual(
            text(KeepAwakeReply(state: .idle, failure: .invalidDuration, thermal: .nominal, thermalGuard: true)),
            #"{"failure":{"invalidDuration":{}},"state":{"idle":{}},"thermal":"nominal","thermalGuard":true}"#
        )
        // Each is written only when present.
        XCTAssertEqual(
            text(KeepAwakeReply(state: .idle, failure: nil, thermal: .fair, thermalGuard: nil)),
            #"{"state":{"idle":{}},"thermal":"fair"}"#
        )
        XCTAssertEqual(
            text(KeepAwakeReply(state: .idle, failure: nil, thermal: nil, thermalGuard: true)),
            #"{"state":{"idle":{}},"thermalGuard":true}"#
        )
    }

    /// A 4.3.0 app answered by a helper that has the guard skips the two keys.
    func testABuildBeforeTheGuardReadsTheNewReply() {
        let armed = #"{"state":{"armed":{"deadline":1793007200,"floorEnabled":true}},"thermal":"critical","thermalGuard":true}"#
        XCTAssertEqual(
            text(KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil, thermal: .critical, thermalGuard: true)),
            armed
        )
        XCTAssertEqual(
            KeepAwakeCoding.decode(KeepAwakeLegacy.Reply.self, from: Data(armed.utf8)),
            KeepAwakeLegacy.Reply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil)
        )
        let refused = #"{"failure":{"invalidDuration":{}},"state":{"idle":{}},"thermal":"nominal","thermalGuard":true}"#
        XCTAssertEqual(
            KeepAwakeCoding.decode(KeepAwakeLegacy.Reply.self, from: Data(refused.utf8)),
            KeepAwakeLegacy.Reply(state: .idle, failure: .invalidDuration)
        )
    }

    /// A value a later helper writes that this build cannot read is absent; the state, the
    /// failure and the other key still read. A level this build does not know, or one that is
    /// not a string, is no level; a guard that is not a JSON boolean (a string, a number, null)
    /// is no guard, so that helper is asked nothing new.
    func testAValueThisBuildCannotReadIsAbsent() {
        XCTAssertEqual(
            reply(#"{"state":{"idle":{}},"thermal":"molten","thermalGuard":true}"#),
            KeepAwakeReply(state: .idle, failure: nil, thermal: nil, thermalGuard: true)
        )
        XCTAssertEqual(
            reply(#"{"state":{"idle":{}},"thermal":"fair","thermalGuard":"yes"}"#),
            KeepAwakeReply(state: .idle, failure: nil, thermal: .fair, thermalGuard: nil)
        )
        XCTAssertEqual(
            reply(#"{"state":{"idle":{}},"thermal":3,"thermalGuard":1}"#),
            KeepAwakeReply(state: .idle, failure: nil, thermal: nil, thermalGuard: nil)
        )
        XCTAssertEqual(
            reply(#"{"state":{"idle":{}},"thermal":null,"thermalGuard":null}"#),
            KeepAwakeReply(state: .idle, failure: nil, thermal: nil, thermalGuard: nil)
        )
        XCTAssertEqual(
            reply(#"{"failure":{"readBack":{"expected":true}},"state":{"armed":{"deadline":1793007200,"floorEnabled":false}},"thermal":{"level":"fair"},"thermalGuard":[true]}"#),
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: false), failure: .readBack(expected: true), thermal: nil, thermalGuard: nil)
        )
    }
}
