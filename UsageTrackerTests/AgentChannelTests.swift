import XCTest
@testable import Omelette

@MainActor
final class AgentChannelTests: XCTestCase {
    private var socketURL: URL!
    private var channel: AgentChannel!
    /// `start()` rotates the session log. Every test passes this temp URL, so the
    /// owner's real `agent-sessions.jsonl` is never read, rewritten or created.
    private var historyURL: URL!

    // The async overrides are what let a @MainActor test class touch its own
    // properties here; the synchronous ones are nonisolated and warn.
    override func setUp() async throws {
        socketURL = AgentFixture.temporarySocketURL()
        historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChannelTests-\(UUID().uuidString).jsonl")
        channel = AgentChannel()
    }

    override func tearDown() async throws {
        channel.stop()
        try? FileManager.default.removeItem(at: socketURL)
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: historyURL.path + ".lock"))
    }

    private func waitOnMain(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testStartBindsTheSocketAndPublishesTheServerForDiagnostics() throws {
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)

        let server = try XCTUnwrap(channel.server)
        XCTAssertNil(channel.startError)
        XCTAssertTrue(AgentDiagnostics.server === server)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testEventsReachTheConsumerOnTheMainActor() throws {
        var kinds: [AgentEvent.Kind] = []
        channel.onEvent = { event, _ in kinds.append(event.kind) }
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)

        AgentSocketTestClient.send(AgentFixture.envelope(payload: AgentFixture.userPromptSubmit) + Data([0x0A]), to: socketURL.path)

        XCTAssertTrue(waitOnMain { kinds == [.promptSubmitted] }, "got \(kinds)")
    }

    func testSecondStartIsANoOp() throws {
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        let first = try XCTUnwrap(channel.server)
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        XCTAssertTrue(channel.server === first)
    }

    func testStartFailureIsRecordedNotThrown() {
        let tooLong = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "x", count: 120) + ".sock")
        channel.start(socketURL: tooLong, refreshSymlink: false, historyURL: historyURL)
        XCTAssertNil(channel.server)
        XCTAssertNotNil(channel.startError)
    }

    func testStopRemovesTheSocketFile() {
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        channel.stop()
        XCTAssertNil(channel.server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testStartRotatesTheSessionLogInTheBackground() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChannelRotation-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: logURL.path + ".lock"))
        }

        let store = AgentHistoryStore(fileURL: logURL)
        // 2024-01-01 — years outside any 90-day window.
        try store.append(AgentSessionRecord(
            id: "claude:ancient", source: .claude, project: "Ancient",
            startedAt: Date(timeIntervalSince1970: 1_704_100_000),
            endedAt: Date(timeIntervalSince1970: 1_704_103_600),
            turns: 2, needsYouCount: 0
        ))
        try store.append(AgentSessionRecord(
            id: "claude:fresh", source: .claude, project: "Fresh",
            startedAt: Date().addingTimeInterval(-3600), endedAt: Date(),
            turns: 2, needsYouCount: 0
        ))

        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: logURL)

        // The rotation is detached, so poll the main run loop instead of assuming it ran.
        XCTAssertTrue(waitOnMain { ((try? store.load()) ?? []).map(\.id) == ["claude:fresh"] })
    }

    func testTheDefaultConsumerAnswersAHeldPermissionWithNoDecision() throws {
        // Nobody assigned onEvent (a unit test, or bootstrap not yet run): a held
        // helper must still be released rather than wait out the 140 s budget.
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        let line = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: AgentFixture.requestID) + Data([0x0A])
        let fd = try XCTUnwrap(AgentSocketTestClient.open(line, to: socketURL.path))
        defer { close(fd) }

        var reply: String?
        // Read only until something arrives: waitOnMain re-checks the condition after
        // its loop, and a second readLine on the consumed line would see EOF.
        XCTAssertTrue(waitOnMain {
            if reply == nil { reply = AgentSocketTestClient.readLine(fd, timeout: 0.05) }
            return reply != nil
        })
        XCTAssertEqual(reply, #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
    }

    func testAHeldPermissionReachesTheConsumerWithAnUnsettledReply() throws {
        var replies: [AgentReply] = []
        channel.onEvent = { _, reply in replies.append(reply) }
        channel.start(socketURL: socketURL, refreshSymlink: false, historyURL: historyURL)
        let line = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, requestID: AgentFixture.requestID) + Data([0x0A])
        let fd = try XCTUnwrap(AgentSocketTestClient.open(line, to: socketURL.path))
        defer { close(fd) }

        XCTAssertTrue(waitOnMain { replies.count == 1 })
        XCTAssertEqual(replies.first?.isSettled, false)
        replies.first?.send(.deny)
        XCTAssertEqual(AgentSocketTestClient.readLine(fd), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"#)
    }

    // MARK: - AgentEventRouter (bootstrap wiring)

    private func makeStoreAndBroker(userAway: Bool = true) -> (AgentSessionStore, PermissionBroker) {
        let store = AgentSessionStore(historyURL: historyURL)
        let presence = PresenceMonitor(frontmost: { userAway ? (1, "com.other") : (4242, "com.googlecode.iterm2") }, hostHasVisibleWindow: { _ in true })
        let broker = PermissionBroker(store: store, presence: presence, featureEnabled: { true })
        return (store, broker)
    }

    private func permissionEvent(requestID: String? = AgentFixture.requestID) -> AgentEvent {
        AgentEvent(source: .claude, kind: .permissionRequested, sessionID: "s1", cwd: "/Users/tester/Projects/alpha",
                   toolName: "Edit", toolSummary: "Edit: WalletView.swift", isSubagent: false,
                   host: AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: nil),
                   receivedAt: Date(), requestID: requestID)
    }

    func testRouterRegistersWithTheBrokerBeforeApplyingToTheStore() {
        let (store, broker) = makeStoreAndBroker()
        var pendingInsideNeedsYou: String??
        store.onNeedsYou = { [broker] session in pendingInsideNeedsYou = .some(broker.pending(for: session.id)?.id) }
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }

        AgentEventRouter.handle(permissionEvent(), reply: reply, store: store, broker: broker)

        XCTAssertEqual(pendingInsideNeedsYou, .some(AgentFixture.requestID), "onNeedsYou must already see the held request")
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertEqual(store.sessions.first?.pendingPermissionID, AgentFixture.requestID)
        XCTAssertFalse(reply.isSettled)
    }

    func testRouterReleasesWhenTheUserIsAtTheTerminalAndStillAppliesTheEvent() {
        let (store, broker) = makeStoreAndBroker(userAway: false)
        let (reply, peer) = AgentFixture.replyPair()
        defer { close(peer) }

        AgentEventRouter.handle(permissionEvent(), reply: reply, store: store, broker: broker)

        XCTAssertTrue(reply.isSettled)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertEqual(store.sessions.first?.state, .needsYou, "the row still shows needs-you; Claude is prompting in the terminal")
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }

    func testRouterHandsTheStoredSessionToTheBroker() {
        // Second request in a session the store already knows: the broker gets the row.
        let (store, broker) = makeStoreAndBroker()
        let first = AgentFixture.replyPair(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        defer { close(first.peer) }
        AgentEventRouter.handle(permissionEvent(requestID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), reply: first.reply, store: store, broker: broker)
        broker.answer(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .allow)

        let second = AgentFixture.replyPair(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        defer { close(second.peer) }
        var hostless = permissionEvent(requestID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        hostless = AgentEvent(source: hostless.source, kind: hostless.kind, sessionID: hostless.sessionID, cwd: hostless.cwd,
                              toolName: hostless.toolName, toolSummary: hostless.toolSummary, isSubagent: false,
                              host: .none, receivedAt: hostless.receivedAt, requestID: hostless.requestID)
        AgentEventRouter.handle(hostless, reply: second.reply, store: store, broker: broker)

        XCTAssertEqual(broker.pending.map(\.id), ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"], "the session's stored host made the hold possible")
    }

    func testRouterOnlyAppliesNonPermissionEvents() {
        let (store, broker) = makeStoreAndBroker()
        let reply = AgentReply(requestID: nil)
        let stop = AgentEvent(source: .claude, kind: .stop, sessionID: "s1", cwd: nil, toolName: nil, toolSummary: nil,
                              isSubagent: false, host: .none, receivedAt: Date())

        AgentEventRouter.handle(stop, reply: reply, store: store, broker: broker)

        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertTrue(broker.pending.isEmpty)
    }

    func testRouterAppliesAPermissionWithoutAnIDWithoutHolding() {
        let (store, broker) = makeStoreAndBroker()
        AgentEventRouter.handle(permissionEvent(requestID: nil), reply: AgentReply(requestID: nil), store: store, broker: broker)
        XCTAssertEqual(store.sessions.first?.state, .needsYou)
        XCTAssertTrue(broker.pending.isEmpty)
        XCTAssertNil(store.sessions.first?.pendingPermissionID)
    }
}
