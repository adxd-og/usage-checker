import XCTest
@testable import Omelette

/// Spec 2026-10-26 § Helper: "Every transition writes the state to
/// /Library/Application Support/Omelette/keepawake.json (root-owned) so state() answers
/// after a daemon restart", and "arm, disarm, state → KeepAwakeState (Codable)".
final class KeepAwakeStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("Omelette/keepawake.json"))
    }

    private func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    func testAStateWrittenIsTheStateRead() throws {
        let states: [KeepAwakeState] = [
            .idle,
            .armed(deadline: t0 + 3_600, floorEnabled: false),
            .ended(at: t0, reason: .batteryFloor),
        ]
        for state in states {
            try file.save(state)
            XCTAssertEqual(file.load(), state)
        }
    }

    func testTheFolderIsCreatedOnTheFirstWrite() throws {
        try file.save(.idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testNoFileReadsAsNothing() {
        XCTAssertNil(file.load())
    }

    func testAnUnreadableFileReadsAsNothing() throws {
        try writeRaw("not json")
        XCTAssertNil(file.load())
    }

    func testAFileFromAnotherVersionReadsAsNothing() throws {
        try writeRaw(#"{"state":{"idle":{}},"version":2}"#)
        XCTAssertNil(file.load())
    }

    /// The shape on disk, pinned: a later build reads what this one wrote.
    func testTheFileShapeIsPinned() throws {
        try writeRaw(#"{"state":{"armed":{"deadline":1793003600,"floorEnabled":true}},"version":1}"#)
        XCTAssertEqual(file.load(), .armed(deadline: Date(timeIntervalSince1970: 1_793_003_600), floorEnabled: true))
    }

    func testEveryReplySurvivesTheTripOverXPC() {
        let failures: [KeepAwakeFailure?] = [
            nil, .commandFailed(command: "pmset", status: 1), .readBack(expected: false), .invalidDuration,
            .helperUnavailable(reason: "gone"), .helperTimedOut, .unreadableReply, .notSigned,
            .registrationFailed(reason: "denied"), .unregisterFailed(reason: "not found"), .adminCancelled, .flagStillSet,
        ]
        for failure in failures {
            let reply = KeepAwakeReply(state: .ended(at: t0, reason: .deadline), failure: failure)
            XCTAssertEqual(KeepAwakeCoding.decode(KeepAwakeReply.self, from: KeepAwakeCoding.encode(reply)), reply)
        }
    }

    func testOnlyAnArmedStateHasADeadline() {
        XCTAssertTrue(KeepAwakeState.armed(deadline: t0, floorEnabled: true).isArmed)
        XCTAssertEqual(KeepAwakeState.armed(deadline: t0, floorEnabled: true).deadline, t0)
        XCTAssertFalse(KeepAwakeState.idle.isArmed)
        XCTAssertNil(KeepAwakeState.idle.deadline)
        XCTAssertFalse(KeepAwakeState.ended(at: t0, reason: .cancelled).isArmed)
        XCTAssertNil(KeepAwakeState.ended(at: t0, reason: .cancelled).deadline)
    }

    /// Review C6: the client's transport hands failures back as `Result<_, KeepAwakeFailure>`.
    func testAFailureTravelsAsAResultsError() {
        let result: Result<KeepAwakeReply, KeepAwakeFailure> = .failure(.helperTimedOut)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? KeepAwakeFailure, .helperTimedOut)
        }
    }
}
