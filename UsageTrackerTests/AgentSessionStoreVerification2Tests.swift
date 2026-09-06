import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `AgentSessionStore.apply`: items 2 and 3 of the batch brief.
///
/// Item 2: while a permission is held for a session (`pendingPermissionIDs` holds its
/// id), `.toolStarted`/`.toolFinished` must leave activity/detail/attention/state
/// alone for *that* session — but a hold on session A must never freeze session B,
/// and releasing A's hold must let A's own tool events move it again.
///
/// Item 3: `.notificationIdle` while `attention != nil` is ignored, but once that
/// attention has actually been cleared (by the matching `PostToolUse`), the next
/// `.notificationIdle` must still be able to send the session idle.
@MainActor
final class AgentSessionStoreVerification2Tests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_500_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> AgentSessionStore {
        AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
    }

    private func event(
        _ kind: AgentEvent.Kind,
        sessionID: String,
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolDetail: String? = nil,
        attention: AgentAttention? = nil
    ) -> AgentEvent {
        AgentEvent(
            source: .claude, kind: kind, sessionID: sessionID, cwd: "/Users/tester/Projects/\(sessionID)",
            toolName: toolName, toolSummary: toolSummary, toolDetail: toolDetail, attention: attention,
            isSubagent: false, host: AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: nil),
            receivedAt: t0
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func session(_ store: AgentSessionStore, _ sessionID: String) -> AgentSession? {
        store.sessions.first { $0.id == "claude:\(sessionID)" }
    }

    // MARK: - Item 2: a hold on one session must not freeze another

    func testAHoldOnSessionADoesNotBlockSessionBsToolEvents() {
        let store = makeStore()

        // Both sessions start.
        store.apply(event(.sessionStart, sessionID: "sA"), now: t0)
        store.apply(event(.sessionStart, sessionID: "sB"), now: t0)

        // Session A has a permission held for it.
        store.setPendingPermission(id: "req-A", for: "claude:sA")

        // A tool call for session B must update B normally, untouched by A's hold.
        store.apply(event(.toolStarted, sessionID: "sB", toolName: "Bash", toolSummary: "swift build", toolDetail: "swift build -q"), now: at(1))

        let b = session(store, "sB")
        XCTAssertEqual(b?.activity, "swift build", "session B's own tool event must not be swallowed by A's hold")
        XCTAssertEqual(b?.activityDetail, "swift build -q")
        XCTAssertEqual(b?.state, .working)

        // And a PreToolUse/PostToolUse pair for A itself is still suppressed.
        store.apply(event(.toolStarted, sessionID: "sA", toolName: "Read", toolSummary: "Read A.swift", toolDetail: "/tmp/A.swift"), now: at(2))
        let a = session(store, "sA")
        XCTAssertNil(a?.activity, "A is held; its own tool events must not rewrite the row either")
        XCTAssertEqual(a?.pendingPermissionID, "req-A")

        // Releasing A's hold lets A's own tool events move it again.
        store.setPendingPermission(id: nil, for: "claude:sA")
        store.apply(event(.toolStarted, sessionID: "sA", toolName: "Read", toolSummary: "Read A.swift", toolDetail: "/tmp/A.swift"), now: at(3))
        let aAfter = session(store, "sA")
        XCTAssertEqual(aAfter?.activity, "Read A.swift", "the hold ended; A's tool events resume updating the row")
        XCTAssertEqual(aAfter?.state, .working)

        // B was never touched by any of A's back-and-forth.
        let bStill = session(store, "sB")
        XCTAssertEqual(bStill?.activity, "swift build")
        XCTAssertEqual(bStill?.state, .working)
    }

    func testAHoldOnSessionABlocksToolFinishedForAEvenWhileBKeepsMoving() {
        let store = makeStore()
        store.apply(event(.toolStarted, sessionID: "sA", toolName: "AskUserQuestion",
                          toolSummary: "Question: Ship?", attention: .question(count: 1, multiSelect: false)), now: t0)
        store.setPendingPermission(id: "req-A", for: "claude:sA")

        // A PostToolUse for the very tool that would normally clear attention must
        // still be suppressed while A is held.
        store.apply(event(.toolFinished, sessionID: "sA", toolName: "AskUserQuestion", toolSummary: "Question: Ship?"), now: at(1))
        XCTAssertEqual(session(store, "sA")?.attention, .question(count: 1, multiSelect: false), "held: the answer-clearing PostToolUse must not fire")

        // Meanwhile B, never held, answers its own question normally.
        store.apply(event(.toolStarted, sessionID: "sB", toolName: "AskUserQuestion",
                          toolSummary: "Question: Ship?", attention: .question(count: 1, multiSelect: false)), now: at(1))
        store.apply(event(.toolFinished, sessionID: "sB", toolName: "AskUserQuestion", toolSummary: "Question: Ship?"), now: at(2))
        XCTAssertNil(session(store, "sB")?.attention, "B was never held, so its own PostToolUse clears its attention")
        XCTAssertEqual(session(store, "sB")?.state, .working)
    }

    // MARK: - Item 3: notificationIdle after the attention that blocked it clears

    func testNotificationIdleGoesIdleOnceTheAttentionThatBlockedItIsCleared() {
        let store = makeStore()
        store.apply(event(.toolStarted, sessionID: "sA", toolName: "AskUserQuestion",
                          toolSummary: "Question: Tabs or spaces?",
                          attention: .question(count: 1, multiSelect: false)), now: t0)

        // While the question is open, the idle prompt is ignored (already covered
        // elsewhere) — confirm it here too as the baseline for what follows.
        store.apply(event(.notificationIdle, sessionID: "sA"), now: at(60))
        XCTAssertEqual(session(store, "sA")?.state, .needsYou, "the question is still open; idle must not fire")

        // The matching PostToolUse answers it: attention clears, state goes to working.
        store.apply(event(.toolFinished, sessionID: "sA", toolName: "AskUserQuestion", toolSummary: "Question: Tabs or spaces?"), now: at(61))
        XCTAssertNil(session(store, "sA")?.attention)
        XCTAssertEqual(session(store, "sA")?.state, .working)

        // Now that attention is nil again, notificationIdle must be able to send the
        // session idle — the same event kind, a different outcome, because the
        // condition it gates on has genuinely changed.
        store.apply(event(.notificationIdle, sessionID: "sA"), now: at(120))
        XCTAssertEqual(session(store, "sA")?.state, .idle, "attention is gone; the idle prompt must be honoured")
    }

    func testNotificationIdleGoesIdleAfterAPlanAttentionIsCleared() {
        let store = makeStore()
        store.apply(event(.toolStarted, sessionID: "sA", toolName: "ExitPlanMode",
                          toolSummary: "Plan ready for review: X", attention: .plan), now: t0)
        store.apply(event(.notificationIdle, sessionID: "sA"), now: at(60))
        XCTAssertEqual(session(store, "sA")?.state, .needsYou, "an open plan blocks idle")

        store.apply(event(.toolFinished, sessionID: "sA", toolName: "ExitPlanMode", toolSummary: "Plan ready for review: X"), now: at(61))
        XCTAssertNil(session(store, "sA")?.attention)

        store.apply(event(.notificationIdle, sessionID: "sA"), now: at(122))
        XCTAssertEqual(session(store, "sA")?.state, .idle)
    }
}
