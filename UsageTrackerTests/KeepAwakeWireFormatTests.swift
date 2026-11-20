import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Daemon: "The state file and the XPC answer stay
/// readable across an update in both directions". The bytes the helper and the app speak in
/// 4.3.0, pinned before the guard changes anything, and how this build reads what 4.3.0 wrote.
final class KeepAwakeWireFormatTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeWireFormatTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private func text<T: Encodable>(_ value: T) -> String {
        String(decoding: KeepAwakeCoding.encode(value), as: UTF8.self)
    }

    private func writeFile(_ text: String) throws {
        try Data(text.utf8).write(to: stateFile.url)
    }

    private func fileText() throws -> String {
        String(decoding: try Data(contentsOf: stateFile.url), as: UTF8.self)
    }

    func testTodaysStatesEncodeAsTheyAlwaysHave() {
        XCTAssertEqual(text(KeepAwakeState.idle), #"{"idle":{}}"#)
        XCTAssertEqual(
            text(KeepAwakeState.armed(deadline: t0 + 7_200, floorEnabled: true)),
            #"{"armed":{"deadline":1793007200,"floorEnabled":true}}"#
        )
        let reasons: [(KeepAwakeEndReason, String)] = [
            (.deadline, "deadline"), (.batteryFloor, "batteryFloor"), (.cancelled, "cancelled"),
            (.restarted, "restarted"), (.stopped, "stopped"),
        ]
        for (reason, raw) in reasons {
            XCTAssertEqual(
                text(KeepAwakeState.ended(at: t0, reason: reason)),
                #"{"ended":{"at":1793000000,"reason":"\#(raw)"}}"#
            )
        }
    }

    func testTodaysRepliesEncodeAsTheyAlwaysHave() {
        XCTAssertEqual(text(KeepAwakeReply(state: .idle, failure: nil)), #"{"state":{"idle":{}}}"#)
        XCTAssertEqual(
            text(KeepAwakeReply(state: .ended(at: t0 + 120, reason: .deadline), failure: .commandFailed(command: "pmset", status: 1))),
            #"{"failure":{"commandFailed":{"command":"pmset","status":1}},"state":{"ended":{"at":1793000120,"reason":"deadline"}}}"#
        )
    }

    func testTodaysFileIsWrittenAsItAlwaysWas() throws {
        try stateFile.save(.idle)
        XCTAssertEqual(try fileText(), #"{"state":{"idle":{}},"version":1}"#)
        try stateFile.save(.ended(at: t0, reason: .deadline), sleepOwed: true, ownsFlag: true)
        XCTAssertEqual(
            try fileText(),
            #"{"ownsFlag":true,"sleepOwed":true,"state":{"ended":{"at":1793000000,"reason":"deadline"}},"version":1}"#
        )
    }

    func testAFileTodaysBuildWroteReadsTheSame() throws {
        try writeFile(#"{"ownsFlag":true,"sleepOwed":true,"state":{"ended":{"at":1793000000,"reason":"deadline"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .deadline))
        XCTAssertTrue(stateFile.loadOwnsFlag())
        XCTAssertTrue(stateFile.loadSleepOwed())
        try writeFile(#"{"failure":{"readBack":{"expected":false}},"ownsFlag":true,"state":{"ended":{"at":1793000060,"reason":"stopped"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0 + 60, reason: .stopped))
        XCTAssertEqual(stateFile.loadFailure(), .readBack(expected: false))
        XCTAssertTrue(stateFile.loadOwnsFlag())
        XCTAssertFalse(stateFile.loadSleepOwed())
    }

    /// A key this build does not know (a later build's) is skipped, at the top and inside a state.
    func testKeysThisBuildDoesNotKnowAreSkipped() throws {
        XCTAssertEqual(
            KeepAwakeCoding.decode(
                KeepAwakeReply.self,
                from: Data(#"{"later":[1,2],"state":{"armed":{"deadline":1793007200,"floorEnabled":true,"later":"x"}}}"#.utf8)
            ),
            KeepAwakeReply(state: .armed(deadline: t0 + 7_200, floorEnabled: true), failure: nil)
        )
        try writeFile(#"{"later":true,"ownsFlag":true,"state":{"ended":{"at":1793000000,"later":1,"reason":"cancelled"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .cancelled))
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }

    /// Why a new way to end is a new reason and never a new state: a state whose key is not
    /// idle, armed or ended does not read, and the file around it reads as nothing, the flag it
    /// owned included.
    func testAStateThisBuildDoesNotKnowReadsAsNothing() throws {
        XCTAssertNil(KeepAwakeCoding.decode(KeepAwakeState.self, from: Data(#"{"paused":{}}"#.utf8)))
        try writeFile(#"{"ownsFlag":true,"state":{"paused":{}},"version":1}"#)
        XCTAssertNil(stateFile.load())
        XCTAssertFalse(stateFile.loadOwnsFlag())
    }
}
