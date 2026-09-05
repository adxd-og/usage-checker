import XCTest
@testable import Omelette

/// Independent verification of `AgentSessionStore.apply`'s attention handling against
/// `docs/superpowers/specs/2026-09-06-clear-requests-and-codex-approvals-design.md`
/// § "Store" and the plan's Task 5 transition table, exercised directly rather than by
/// re-reading `AgentSessionStoreTests.swift`. Focuses on the interactions the spec
/// calls out explicitly: another tool's PreToolUse/PostToolUse must not disturb an
/// active attention, a real `PermissionRequest` arriving while attention is held must
/// set `pendingPermissionID` without dropping the attention, and a needsYou episode
/// started by the attention must not be double-counted by a permission request that
/// follows it for the same session.
@MainActor
final class AgentSessionStoreAttentionVerificationTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreAttentionVerificationTests-\(UUID().uuidString)", isDirectory: true)
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
        sessionID: String = "s1",
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolDetail: String? = nil,
        attention: AgentAttention? = nil,
        requestID: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            source: .claude, kind: kind, sessionID: sessionID, cwd: "/Users/tester/Projects/alpha",
            toolName: toolName, toolSummary: toolSummary, toolDetail: toolDetail, attention: attention,
            isSubagent: false, host: AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: nil),
            receivedAt: t0, requestID: requestID
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Another tool's events leave a held attention alone

    func testABashPreAndPostToolUseWhileAQuestionIsPendingTouchesNothing() {
        let store = makeStore()
        store.apply(event(
            .toolStarted, toolName: "AskUserQuestion",
            toolSummary: "Question: Tabs or spaces?", toolDetail: "Tabs or spaces?\n• Tabs\n• Spaces",
            attention: .question(count: 1, multiSelect: false)
        ), now: t0)

        // The agent may run pre-approved tool calls alongside the one that is
        // waiting; none of that is the answer.
        store.apply(event(.toolStarted, toolName: "Bash", toolSummary: "swift build", toolDetail: "swift build -q"), now: at(1))
        store.apply(event(.toolFinished, toolName: "Bash", toolSummary: "swift build"), now: at(2))

        let session = store.sessions.first
        XCTAssertEqual(session?.state, .needsYou)
        XCTAssertEqual(session?.attention, .question(count: 1, multiSelect: false))
        XCTAssertEqual(session?.activity, "Question: Tabs or spaces?", "the Bash headline must not steal the row")
        XCTAssertEqual(session?.activityDetail, "Tabs or spaces?\n• Tabs\n• Spaces")
        XCTAssertEqual(session?.needsYouCount, 1)
    }

    func testAPlanIsUndisturbedByAnUnrelatedToolFinishing() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "ExitPlanMode", toolSummary: "Plan ready for review: X", toolDetail: "# X", attention: .plan), now: t0)
        store.apply(event(.toolFinished, toolName: "Read", toolSummary: "Read A.swift", toolDetail: "/tmp/A.swift"), now: at(1))

        XCTAssertEqual(store.sessions.first?.attention, .plan)
        XCTAssertEqual(store.sessions.first?.activity, "Plan ready for review: X")
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
    }

    // MARK: - needsYouCount is one episode, not two

    func testAPermissionRequestRightAfterTheAttentionDoesNotDoubleCountTheEpisode() {
        let store = makeStore()
        store.apply(event(
            .toolStarted, toolName: "AskUserQuestion",
            toolSummary: "Question: Tabs or spaces?", attention: .question(count: 1, multiSelect: false)
        ), now: t0)
        XCTAssertEqual(store.sessions.first?.needsYouCount, 1)

        // A PermissionRequest for the same session while the state is already
        // needsYou is not a *new* episode — the edge already fired.
        store.apply(event(.permissionRequested, toolName: "Bash", toolSummary: "Wants to run something", requestID: "req-1"), now: at(1))

        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertEqual(store.sessions.first?.needsYouCount, 1, "one episode, counted once")
    }

    func testTwoSeparateNeedsYouEpisodesAreCountedTwice() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "AskUserQuestion", toolSummary: "Q1", attention: .question(count: 1, multiSelect: false)), now: t0)
        store.apply(event(.toolFinished, toolName: "AskUserQuestion", toolSummary: "Q1", attention: .question(count: 1, multiSelect: false)), now: at(1))
        XCTAssertEqual(store.sessions.first?.state, .working, "answered — the episode is over")

        store.apply(event(.toolStarted, toolName: "ExitPlanMode", toolSummary: "Plan ready for review: Y", attention: .plan), now: at(2))
        XCTAssertEqual(store.sessions.first?.needsYouCount, 2, "a second, distinct needsYou episode")
    }

    // MARK: - PermissionRequest during attention: pendingPermissionID set, attention kept

    func testARealPermissionRequestDuringAttentionSetsThePendingIDWithoutDroppingAttention() {
        let store = makeStore()
        let presence = PresenceMonitor(frontmost: { (1, "com.other.app") }, hostHasVisibleWindow: { _ in true })
        let broker = PermissionBroker(store: store, presence: presence, featureEnabled: { true })
        let (reply, peer) = AgentFixture.replyPair(requestID: AgentFixture.requestID)
        defer { close(peer) }

        // The session is mid-question.
        store.apply(event(
            .toolStarted, toolName: "AskUserQuestion",
            toolSummary: "Question: Tabs or spaces?", attention: .question(count: 1, multiSelect: false)
        ), now: t0)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, nil)

        // A genuine PermissionRequest arrives for the same session (belt-and-braces:
        // spec facts say AskUserQuestion/ExitPlanMode never produce one, but nothing
        // stops some *other* tool's PermissionRequest from landing while the question
        // from a previous tool call is still unanswered).
        let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        let permissionEvent = AgentEvent(
            source: .claude, kind: .permissionRequested, sessionID: "s1", cwd: "/Users/tester/Projects/alpha",
            toolName: "Bash", toolSummary: "Clear the build folder", toolDetail: "rm -rf build",
            isSubagent: false, host: iterm, receivedAt: at(5), requestID: AgentFixture.requestID
        )
        broker.register(event: permissionEvent, reply: reply, session: store.sessions.first, now: at(5))
        store.apply(permissionEvent, now: at(5))

        let session = store.sessions.first
        XCTAssertEqual(session?.pendingPermissionID, AgentFixture.requestID, "the broker's hold is now reflected on the row")
        XCTAssertEqual(session?.attention, .question(count: 1, multiSelect: false), "the question the row was already showing is not cleared by an unrelated hold")
        XCTAssertEqual(session?.state, .needsYou)
    }

    func testPendingPermissionCarriesTheAttentionFromTheEventItself() {
        // Spec/plan attack surface: `PendingPermission.attention` must be set from
        // the registering event, independent of anything already on the session.
        let store = makeStore()
        let presence = PresenceMonitor(frontmost: { (1, "com.other.app") }, hostHasVisibleWindow: { _ in true })
        let broker = PermissionBroker(store: store, presence: presence, featureEnabled: { true })
        let (reply, peer) = AgentFixture.replyPair(requestID: AgentFixture.requestID)
        defer { close(peer) }

        let iterm = AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        let questionPermission = AgentEvent(
            source: .claude, kind: .permissionRequested, sessionID: "s1", cwd: "/Users/tester/Projects/alpha",
            toolName: "AskUserQuestion", toolSummary: "Question: Tabs or spaces?", toolDetail: "Tabs or spaces?\n• Tabs",
            attention: .question(count: 1, multiSelect: false),
            isSubagent: false, host: iterm, receivedAt: t0, requestID: AgentFixture.requestID
        )
        broker.register(event: questionPermission, reply: reply, session: nil, now: t0)

        XCTAssertEqual(broker.pending.first?.attention, .question(count: 1, multiSelect: false))
        XCTAssertEqual(broker.pending.first?.detail, "Tabs or spaces?\n• Tabs")
    }

    // MARK: - Clearing

    func testPostToolUseOfTheSameAttentionToolClearsAttentionActivityAndDetail() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "ExitPlanMode", toolSummary: "Plan ready for review: X", toolDetail: "# X", attention: .plan), now: t0)
        store.apply(event(.toolFinished, toolName: "ExitPlanMode", toolSummary: "Plan ready for review: X", toolDetail: "# X", attention: .plan), now: at(1))

        let session = store.sessions.first
        XCTAssertNil(session?.attention)
        XCTAssertNil(session?.activity)
        XCTAssertNil(session?.activityDetail)
        XCTAssertEqual(session?.state, .working)
    }

    func testANewPromptSubmittedClearsAQuestionAttention() {
        let store = makeStore()
        store.apply(event(
            .toolStarted, toolName: "AskUserQuestion", toolSummary: "Question: Ship today?",
            toolDetail: "Ship today?\n• Yes", attention: .question(count: 1, multiSelect: false)
        ), now: t0)
        store.apply(event(.promptSubmitted), now: at(1))

        let session = store.sessions.first
        XCTAssertNil(session?.attention)
        XCTAssertNil(session?.activity)
        XCTAssertNil(session?.activityDetail)
        XCTAssertEqual(session?.state, .working)
    }

    func testStopClearsAQuestionAttentionAndMovesToDone() {
        let store = makeStore()
        store.apply(event(
            .toolStarted, toolName: "AskUserQuestion", toolSummary: "Question: Ship today?",
            attention: .question(count: 1, multiSelect: false)
        ), now: t0)
        store.apply(event(.stop), now: at(1))

        XCTAssertNil(store.sessions.first?.attention)
        XCTAssertEqual(store.sessions.first?.state, .done)
    }

    func testSessionEndDropsTheRowAttentionIncluded() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "ExitPlanMode", toolSummary: "Plan ready for review: X", attention: .plan), now: t0)
        store.apply(event(.sessionEnd), now: at(1))
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
