import XCTest
@testable import Omelette

/// Spec 2026-11-19 keep-awake thermal guard, § Rule ("The reason is `overheated`") and § Daemon
/// ("an app that does not know `overheated` shows the mode as ended"): the new reason travels
/// as `stopped` with `cause: overheated` beside it, so 4.3.0 reads an end, and this build reads
/// what a later one may write.
final class KeepAwakeOverheatedEndTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeepAwakeOverheatedEndTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: KeepAwakeStateFile {
        KeepAwakeStateFile(url: directory.appendingPathComponent("keepawake.json"))
    }

    private func state(_ json: String) -> KeepAwakeState? {
        KeepAwakeCoding.decode(KeepAwakeState.self, from: Data(json.utf8))
    }

    private func writeFile(_ text: String) throws {
        try Data(text.utf8).write(to: stateFile.url)
    }

    func testAnOverheatedEndIsWrittenAsStoppedWithItsCauseBeside() {
        XCTAssertEqual(
            String(decoding: KeepAwakeCoding.encode(KeepAwakeState.ended(at: t0, reason: .overheated)), as: UTF8.self),
            #"{"ended":{"at":1793000000,"cause":"overheated","reason":"stopped"}}"#
        )
    }

    func testThisBuildReadsAnOverheatedEndBack() throws {
        XCTAssertEqual(
            KeepAwakeCoding.decode(
                KeepAwakeReply.self,
                from: Data(#"{"state":{"ended":{"at":1793000000,"cause":"overheated","reason":"stopped"}}}"#.utf8)
            ),
            KeepAwakeReply(state: .ended(at: t0, reason: .overheated), failure: nil)
        )
        try writeFile(#"{"ownsFlag":true,"sleepOwed":true,"state":{"ended":{"at":1793000000,"cause":"overheated","reason":"stopped"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .overheated))
        XCTAssertTrue(stateFile.loadSleepOwed())
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }

    /// A 4.3.0 app answered by a helper that has the guard (a downgrade while armed): it reads an
    /// end, "the helper was stopped", never an unreadable reply that keeps it polling.
    func testABuildBeforeTheGuardReadsAnOverheatedReplyAsStopped() {
        let data = KeepAwakeCoding.encode(KeepAwakeReply(state: .ended(at: t0, reason: .overheated), failure: nil))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"state":{"ended":{"at":1793000000,"cause":"overheated","reason":"stopped"}}}"#
        )
        XCTAssertEqual(
            KeepAwakeCoding.decode(KeepAwakeLegacy.Reply.self, from: data),
            KeepAwakeLegacy.Reply(state: .ended(at: t0, reason: .stopped), failure: nil)
        )
    }

    /// A 4.3.0 helper starting on a file the guard's helper wrote: the flag it owned and the
    /// sleep it owed are still there to act on.
    func testABuildBeforeTheGuardKeepsTheFilesFlagAndSleepBesideAnOverheatedEnd() throws {
        try stateFile.save(.ended(at: t0, reason: .overheated), sleepOwed: true, ownsFlag: true)
        let data = try Data(contentsOf: stateFile.url)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"ownsFlag":true,"sleepOwed":true,"state":{"ended":{"at":1793000000,"cause":"overheated","reason":"stopped"}},"version":1}"#
        )
        XCTAssertEqual(
            KeepAwakeCoding.decode(KeepAwakeLegacy.Envelope.self, from: data),
            KeepAwakeLegacy.Envelope(version: 1, state: .ended(at: t0, reason: .stopped), failure: nil, sleepOwed: true, ownsFlag: true)
        )
    }

    /// A later build's reason, written the same way: this build reads the reason beside it. A
    /// cause that is not a string is no cause either.
    func testACauseThisBuildDoesNotKnowFallsBackToTheReasonBesideIt() {
        XCTAssertEqual(
            state(#"{"ended":{"at":1793000000,"cause":"melted","reason":"cancelled"}}"#),
            .ended(at: t0, reason: .cancelled)
        )
        XCTAssertEqual(
            state(#"{"ended":{"at":1793000000,"cause":7,"reason":"cancelled"}}"#),
            .ended(at: t0, reason: .cancelled)
        )
    }

    /// A reason this build does not know under `reason` itself: an end all the same, and the file
    /// around it keeps its flag.
    func testAReasonThisBuildDoesNotKnowReadsAsStopped() throws {
        XCTAssertEqual(state(#"{"ended":{"at":1793000000,"reason":"melted"}}"#), .ended(at: t0, reason: .stopped))
        try writeFile(#"{"ownsFlag":true,"state":{"ended":{"at":1793000000,"reason":"melted"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .stopped))
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }

    /// Only the new reason needs a stand-in; every reason 4.3.0 knows is written as itself.
    func testOnlyOverheatedIsWrittenAsAnotherReason() {
        XCTAssertEqual(KeepAwakeEndReason.allCases.filter { $0.olderBuildsRead != $0 }, [.overheated])
        XCTAssertEqual(KeepAwakeEndReason.overheated.olderBuildsRead, .stopped)
    }

    // Spec § Accepted risks: "An `ended` state decodes whenever its time does: a missing or
    // unreadable reason reads as `stopped`, so the file never loses the helper's claim on the
    // flag over one field."

    func testAnEndWithAKnownCauseAndNoReasonReadsAsTheCauseAndKeepsTheFlag() throws {
        try writeFile(#"{"ownsFlag":true,"state":{"ended":{"at":1793000000,"cause":"overheated"}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .overheated))
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }

    func testAReasonThatIsNotAStringIsSkippedAndTheFlagKept() throws {
        try writeFile(#"{"ownsFlag":true,"state":{"ended":{"at":1793000000,"cause":"overheated","reason":7}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .overheated))
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }

    func testAnEndWithNeitherReasonNorCauseReadsAsStoppedAndKeepsTheFlag() throws {
        try writeFile(#"{"ownsFlag":true,"state":{"ended":{"at":1793000000}},"version":1}"#)
        XCTAssertEqual(stateFile.load(), .ended(at: t0, reason: .stopped))
        XCTAssertTrue(stateFile.loadOwnsFlag())
    }
}
