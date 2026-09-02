import XCTest
@testable import Omelette

@MainActor
final class AgentSessionStoreTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var historyURL: URL { directory.appendingPathComponent("agent-sessions.jsonl") }

    private func makeStore() -> AgentSessionStore {
        AgentSessionStore(historyURL: historyURL)
    }

    private func event(
        _ kind: AgentEvent.Kind,
        source: AgentSource = .claude,
        sessionID: String = "s1",
        cwd: String? = "/Users/tester/Projects/alpha",
        toolName: String? = nil,
        toolSummary: String? = nil,
        isSubagent: Bool = false,
        pid: Int32? = nil
    ) -> AgentEvent {
        AgentEvent(
            source: source,
            kind: kind,
            sessionID: sessionID,
            cwd: cwd,
            toolName: toolName,
            toolSummary: toolSummary,
            isSubagent: isSubagent,
            host: AgentHostInfo(pid: pid, bundleID: nil, tty: nil),
            receivedAt: t0
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The transition table

    func testEveryClaudeTransition() {
        let cases: [(AgentEvent.Kind, AgentState)] = [
            (.sessionStart, .idle),
            (.promptSubmitted, .working),
            (.toolStarted, .working),
            (.toolFinished, .working),
            (.permissionRequested, .needsYou),
            (.notificationPermission, .needsYou),
            (.notificationIdle, .idle),
            (.stop, .done),
        ]
        for (kind, expected) in cases {
            let store = makeStore()
            store.apply(event(.sessionStart), now: t0)
            store.apply(event(kind), now: at(10))
            XCTAssertEqual(store.sessions.first?.state, expected, "\(kind) must land in \(expected)")
        }
    }

    func testCodexTurnCompleteFinishesTheSession() {
        let store = makeStore()
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "t1"), now: t0)
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(store.sessions.first?.source, .codex)
        XCTAssertEqual(store.sessions.first?.id, "codex:t1")
    }

    func testSessionEndRemovesTheSession() {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(1))
        store.apply(event(.sessionEnd), now: at(2))
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testSessionEndForAnUnknownSessionIsHarmless() {
        let store = makeStore()
        store.apply(event(.sessionEnd, sessionID: "never-seen"), now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.lastEventAt, t0)
    }

    // MARK: - Ignore rules

    func testSubagentEventsAreIgnoredEntirely() {
        let store = makeStore()
        store.apply(event(.sessionStart, sessionID: "sub", isSubagent: true), now: t0)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.lastEventAt, "an ignored event is not activity")
    }

    func testASubagentEventNeverDisturbsItsParentSession() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.stop, isSubagent: true), now: at(5))
        XCTAssertEqual(store.sessions.first?.state, .working)
        XCTAssertEqual(store.sessions.first?.lastEventAt, t0)
    }

    func testAnUnknownKindOnlyRefreshesActivity() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.toolStarted, toolSummary: "Bash: xcodegen generate"), now: at(5))
        store.apply(event(.unknown("PreCompact")), now: at(60))

        let session = try? XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.stateSince, t0, "an unknown event is not a state change")
        XCTAssertEqual(session?.activity, "Bash: xcodegen generate")
        XCTAssertEqual(session?.lastEventAt, at(60))
        XCTAssertEqual(store.lastEventAt, at(60))
    }

    func testAnUnknownKindDoesNotInventASession() {
        let store = makeStore()
        store.apply(event(.unknown("PreCompact"), sessionID: "never-seen"), now: t0)
        XCTAssertTrue(store.sessions.isEmpty, "we know nothing about this session but its id")
    }

    // MARK: - stateSince

    func testStateSinceMovesOnlyWhenTheStateChanges() {
        let store = makeStore()
        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.toolStarted), now: at(30))
        store.apply(event(.toolFinished), now: at(60))
        XCTAssertEqual(store.sessions.first?.stateSince, t0, "still working — the clock keeps running")

        store.apply(event(.stop), now: at(90))
        XCTAssertEqual(store.sessions.first?.stateSince, at(90))
        XCTAssertEqual(store.sessions.first?.state, .done)
    }

    // MARK: - Activity

    func testAPromptClearsTheActivityAndAToolSetsIt() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolName: "Bash", toolSummary: "Bash: git status"), now: t0)
        XCTAssertEqual(store.sessions.first?.activity, "Bash: git status")

        store.apply(event(.promptSubmitted), now: at(5))
        XCTAssertNil(store.sessions.first?.activity, "a new prompt is a new subject")

        store.apply(event(.permissionRequested, toolSummary: "Bash: rm -rf build"), now: at(6))
        XCTAssertEqual(store.sessions.first?.activity, "Bash: rm -rf build")
    }

    func testPostToolUseKeepsTheActivityItHasNoSummaryFor() {
        let store = makeStore()
        store.apply(event(.toolStarted, toolSummary: "Read: PopoverView.swift"), now: t0)
        store.apply(event(.toolFinished, toolName: "Read", toolSummary: nil), now: at(1))
        XCTAssertEqual(store.sessions.first?.activity, "Read: PopoverView.swift")
    }

    // MARK: - Counters

    func testTurnsCountPromptsAndNothingElse() {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(1))
        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.stop), now: at(3))
        store.apply(event(.promptSubmitted), now: at(4))
        XCTAssertEqual(store.sessions.first?.turns, 2)
    }

    func testNeedsYouCountsEpisodesNotEvents() {
        let store = makeStore()
        store.apply(event(.permissionRequested), now: t0)
        store.apply(event(.notificationPermission), now: at(1)) // same episode, the fallback fired too
        XCTAssertEqual(store.sessions.first?.needsYouCount, 1)

        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.permissionRequested), now: at(3))
        XCTAssertEqual(store.sessions.first?.needsYouCount, 2)
    }

    func testStoreLevelCounts() {
        let store = makeStore()
        store.apply(event(.permissionRequested, sessionID: "a"), now: t0)
        store.apply(event(.promptSubmitted, sessionID: "b"), now: at(1))
        store.apply(event(.promptSubmitted, sessionID: "c"), now: at(2))
        store.apply(event(.stop, sessionID: "d"), now: at(3))

        XCTAssertEqual(store.needsYouCount, 1)
        XCTAssertEqual(store.workingCount, 2)
    }

    // MARK: - Callbacks

    func testNeedsYouFiresOncePerEpisode() {
        let store = makeStore()
        var fired: [String] = []
        store.onNeedsYou = { fired.append($0.id) }

        store.apply(event(.permissionRequested), now: t0)
        store.apply(event(.notificationPermission), now: at(1))
        XCTAssertEqual(fired, ["claude:s1"], "one prompt, one notification")

        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.permissionRequested), now: at(3))
        XCTAssertEqual(fired, ["claude:s1", "claude:s1"], "leaving and re-entering is a new episode")
    }

    func testDoneFiresOncePerEpisodeAndCarriesTheSession() {
        let store = makeStore()
        var done: [AgentSession] = []
        store.onDone = { done.append($0) }

        store.apply(event(.promptSubmitted), now: t0)
        store.apply(event(.stop), now: at(1))
        store.apply(event(.stop), now: at(2))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.id, "claude:s1")
        XCTAssertEqual(done.first?.projectName, "Projects / alpha")
        XCTAssertEqual(done.first?.turns, 1)
    }

    func testNoCallbackFiresForAStateThatDidNotChange() {
        let store = makeStore()
        var needsYou = 0
        var done = 0
        store.onNeedsYou = { _ in needsYou += 1 }
        store.onDone = { _ in done += 1 }

        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.notificationIdle), now: at(1))
        store.apply(event(.toolStarted), now: at(2))
        store.apply(event(.toolFinished), now: at(3))
        XCTAssertEqual(needsYou, 0)
        XCTAssertEqual(done, 0)
    }

    // MARK: - Identity and projects

    func testASessionCarriesItsProjectAndHost() {
        let store = makeStore()
        store.apply(
            event(.sessionStart, cwd: "/Users/tester/Projects/alpha", pid: 4242),
            now: t0
        )
        let session = store.sessions.first
        XCTAssertEqual(session?.id, "claude:s1")
        XCTAssertEqual(session?.sessionID, "s1")
        XCTAssertEqual(session?.projectName, "Projects / alpha")
        XCTAssertEqual(session?.cwd, "/Users/tester/Projects/alpha")
        XCTAssertEqual(session?.host.pid, 4242)
        XCTAssertEqual(session?.startedAt, t0)
        XCTAssertFalse(session?.isApproximate ?? true)
    }

    func testTheSameSessionIDFromTwoSourcesIsTwoSessions() {
        let store = makeStore()
        store.apply(event(.promptSubmitted, source: .claude, sessionID: "x"), now: t0)
        store.apply(event(.codexTurnComplete, source: .codex, sessionID: "x"), now: at(1))
        XCTAssertEqual(Set(store.sessions.map(\.id)), ["claude:x", "codex:x"])
        XCTAssertEqual(store.sessions(for: .claude).map(\.id), ["claude:x"])
        XCTAssertEqual(store.sessions(for: .codex).map(\.id), ["codex:x"])
    }

    func testASessionWithoutACwdStillHasAName() {
        let store = makeStore()
        store.apply(event(.sessionStart, cwd: nil), now: t0)
        XCTAssertEqual(store.sessions.first?.projectName, "Unknown project")
    }

    // MARK: - Sorting

    func testSessionsSortByStateThenRecency() {
        let store = makeStore()
        store.apply(event(.sessionStart, sessionID: "idle"), now: t0)
        store.apply(event(.stop, sessionID: "done"), now: at(1))
        store.apply(event(.promptSubmitted, sessionID: "workingOld"), now: at(2))
        store.apply(event(.promptSubmitted, sessionID: "workingNew"), now: at(3))
        store.apply(event(.permissionRequested, sessionID: "needsYou"), now: at(4))

        XCTAssertEqual(
            store.sessions.map(\.sessionID),
            ["needsYou", "workingNew", "workingOld", "done", "idle"]
        )
    }

    // MARK: - History

    func testSessionEndWritesOneHistoryRecord() throws {
        let store = makeStore()
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.promptSubmitted), now: at(10))
        store.apply(event(.permissionRequested), now: at(20))
        store.apply(event(.promptSubmitted), now: at(30))
        store.apply(event(.sessionEnd), now: at(40))

        let records = try AgentHistoryStore(fileURL: historyURL).load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "claude:s1")
        XCTAssertEqual(records.first?.source, .claude)
        XCTAssertEqual(records.first?.project, "Projects / alpha")
        XCTAssertEqual(records.first?.startedAt, t0)
        XCTAssertEqual(records.first?.endedAt, at(40))
        XCTAssertEqual(records.first?.turns, 2)
        XCTAssertEqual(records.first?.needsYouCount, 1)
    }
}
