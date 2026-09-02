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
}
