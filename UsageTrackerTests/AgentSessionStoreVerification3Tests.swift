import XCTest
@testable import Omelette

/// Independent verification of `AgentSessionStore`'s passive Codex lift/undo, derived
/// from `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)", item 2, and the plan's "Session rulings (2026-09-24)" #3, not
/// from `AgentSessionStoreTests`. Focus: the exact boundary named in the task brief
/// (a scan write at T−1 or at exactly T+5 s never lifts, T+6 s does), that the undo
/// restores the precise `stateBeforeScan` rather than a hardcoded fallback, and that a
/// hook event clears the lift mid-flight so a later idle reading has no say.
@MainActor
final class AgentSessionStoreVerification3Tests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_820_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreVerification3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> AgentSessionStore {
        AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func codexEvent(_ kind: AgentEvent.Kind, sessionID: String = "thr-1") -> AgentEvent {
        AgentEvent(
            source: .codex, kind: kind, sessionID: sessionID, cwd: "/Users/tester/Projects/orion",
            toolName: nil, toolSummary: nil, toolDetail: nil, attention: nil,
            isSubagent: false, host: AgentHostInfo(pid: 5150, bundleID: nil, tty: nil), receivedAt: t0
        )
    }

    private func scanReading(sessionID: String = "thr-1", state: AgentState, writtenAt: Date) -> AgentSession {
        AgentSession(
            sessionID: sessionID, source: .codex, projectName: "Projects / orion",
            cwd: "/Users/tester/Projects/orion", state: state, activity: nil,
            stateSince: writtenAt, lastEventAt: writtenAt, startedAt: writtenAt,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil), isApproximate: true
        )
    }

    // MARK: - The exact margin boundary

    /// A rollout write one second before the row's own state change: the turn that
    /// just ended, not a new one.
    func testAWriteOneSecondBeforeTheStopNeverLifts() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)

        store.mergePassive([scanReading(state: .working, writtenAt: at(-1))], now: at(30))

        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(store.sessions.first?.workingFromScan, false)
    }

    /// Exactly the margin (5 s) is still not "more than" it, so this write must not
    /// lift the row.
    func testAWriteExactlyAtTheFiveSecondMarginNeverLifts() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)

        store.mergePassive([scanReading(state: .working, writtenAt: at(5))], now: at(30))

        XCTAssertEqual(store.sessions.first?.state, .done, "exactly 5s after stateSince is not > stateSince + margin")
    }

    /// One second past the margin: this is a new turn, and the row is lifted.
    func testAWriteOneSecondPastTheFiveSecondMarginLifts() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)

        store.mergePassive([scanReading(state: .working, writtenAt: at(6))], now: at(31))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.workingFromScan, true)
        XCTAssertEqual(session?.stateBeforeScan, .done)
        XCTAssertEqual(session?.stateSince, at(31), "the lift's stateSince is the merge's now, not the scan's write time")
    }

    // MARK: - The undo restores the exact previous state

    /// The row was `idle` (never `done`) before the lift; the undo must read
    /// `stateBeforeScan` rather than assume "done" or fall through to a default.
    func testTheUndoRestoresIdleWhenThatWasTheStateBeforeTheLift() {
        let store = makeStore()
        store.apply(codexEvent(.sessionStart), now: t0)
        XCTAssertEqual(store.sessions.first?.state, .idle)

        store.mergePassive([scanReading(state: .working, writtenAt: at(10))], now: at(20))
        XCTAssertEqual(store.sessions.first?.state, .working)
        XCTAssertEqual(store.sessions.first?.stateBeforeScan, .idle)

        // The scan goes quiet: a later read of the same file says idle again.
        store.mergePassive([scanReading(state: .idle, writtenAt: at(45))], now: at(90))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .idle, "restored to idle, not done")
        XCTAssertEqual(session?.stateSince, at(45), "counted from the scan's own last write")
        XCTAssertEqual(session?.workingFromScan, false)
        XCTAssertNil(session?.stateBeforeScan)
    }

    /// The row was `done`; the undo must read that back, and `stateSince` follows the
    /// scan's write, not "now", while the row is still inside the scan's window.
    func testTheUndoRestoresDoneWithTheScansOwnWriteTimeAsStateSince() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)

        store.mergePassive([scanReading(state: .working, writtenAt: at(10))], now: at(25))
        XCTAssertEqual(store.sessions.first?.state, .working)

        store.mergePassive([scanReading(state: .idle, writtenAt: at(200))], now: at(600))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .done)
        XCTAssertEqual(session?.stateSince, at(200), "the scan's write time, not the merge's now")
    }

    /// Once the row has aged out of the scan's 30-minute window there is no write time
    /// left to read, so the undo counts from `now` instead.
    func testTheUndoUsesNowWhenTheRowHasLeftTheScanWindow() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)
        store.mergePassive([scanReading(state: .working, writtenAt: at(10))], now: at(25))

        store.mergePassive([], now: at(7200)) // gone from the scan entirely

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .done)
        XCTAssertEqual(session?.stateSince, at(7200))
    }

    // MARK: - A hook event clears the lift mid-flight

    /// A permission request arrives while the row is a lifted "working": the hook
    /// takes the row over outright (`needsYou`, not `working`), and both lift fields
    /// are cleared so a later idle reading from the scan cannot touch it.
    func testAPermissionRequestDuringALiftTakesTheRowOverAndClearsTheLift() {
        let store = makeStore()
        store.apply(codexEvent(.codexTurnComplete), now: t0)
        store.mergePassive([scanReading(state: .working, writtenAt: at(10))], now: at(25))
        XCTAssertEqual(store.sessions.first?.workingFromScan, true)

        let permissionEvent = AgentEvent(
            source: .codex, kind: .permissionRequested, sessionID: "thr-1",
            cwd: "/Users/tester/Projects/orion", toolName: "apply_patch", toolSummary: "Patch: src/main.rs",
            toolDetail: nil, attention: nil,
            isSubagent: false, host: AgentHostInfo(pid: 5150, bundleID: nil, tty: nil), receivedAt: at(30)
        )
        store.apply(permissionEvent, now: at(30))

        var session = store.sessions.first
        XCTAssertEqual(session?.state, .needsYou)
        XCTAssertEqual(session?.workingFromScan, false)
        XCTAssertNil(session?.stateBeforeScan)

        // A later idle scan reading must not be able to move this row: the hook owns
        // it now, and settledIfTheScanWentQuiet only acts on workingFromScan rows.
        store.mergePassive([scanReading(state: .idle, writtenAt: at(60))], now: at(90))
        session = store.sessions.first
        XCTAssertEqual(session?.state, .needsYou, "the hook's state stands; a quiet file says nothing against it")
    }

    // MARK: - A second lift after an undo records its own stateBeforeScan

    /// Lift, undo, then lift again: the second lift's `stateBeforeScan` must reflect
    /// the row's state at that moment, not a stale value left over from the first.
    func testASecondLiftAfterAnUndoRecordsItsOwnPreviousState() {
        let store = makeStore()
        store.apply(codexEvent(.sessionStart), now: t0) // idle
        store.mergePassive([scanReading(state: .working, writtenAt: at(10))], now: at(20))
        store.mergePassive([scanReading(state: .idle, writtenAt: at(10))], now: at(60)) // undo -> idle again
        XCTAssertEqual(store.sessions.first?.state, .idle)
        XCTAssertNil(store.sessions.first?.stateBeforeScan)

        // A fresh write, well past the margin from the undo's own stateSince (at(10)).
        store.mergePassive([scanReading(state: .working, writtenAt: at(70))], now: at(90))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.workingFromScan, true)
        XCTAssertEqual(session?.stateBeforeScan, .idle, "the second lift's own previous state, freshly recorded")
    }
}
