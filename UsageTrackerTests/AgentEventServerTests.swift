import XCTest
@testable import Omelette

final class AgentEventServerTests: XCTestCase {
    private var socketURL: URL!
    private var server: AgentEventServer?

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertLessThanOrEqual(socketURL.path.utf8.count, AgentPaths.maxSocketPathBytes)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// One wire line: envelope + "\n".
    private func line(_ payload: String, source: String = "claude") -> Data {
        AgentFixture.envelope(source: source, payload: payload) + Data([0x0A])
    }

    /// Two overloads rather than a defaulted `onEvent`: with every closure parameter
    /// defaulted, Swift's forward trailing-closure scan binds `{ _, _ in }` to
    /// `peerUID` and fails; with `onEvent` required it skips `peerUID` as intended.
    private func startServer(
        holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID
    ) throws -> AgentEventServer {
        try startServer(holdTimeout: holdTimeout, peerUID: peerUID, onEvent: { _, _ in })
    }

    private func startServer(
        holdTimeout: TimeInterval = AgentEventServer.defaultHoldTimeout,
        peerUID: @escaping @Sendable (Int32) -> uid_t? = AgentEventServer.localPeerUID,
        onEvent: @escaping @Sendable (AgentEvent, AgentReply) -> Void
    ) throws -> AgentEventServer {
        let server = AgentEventServer(socketURL: socketURL, holdTimeout: holdTimeout, peerUID: peerUID, onEvent: onEvent)
        try server.start()
        self.server = server
        return server
    }

    /// A PermissionRequest line the server will hold: v2 with a request id and a trailing "\n".
    private func heldLine(sessionID: String = "sess-1") -> Data {
        AgentFixture.envelope(payload: AgentFixture.claude("PermissionRequest", sessionID: sessionID, extra: #""tool_name":"Bash","tool_input":{"command":"rm -rf build"}"#),
                              requestID: AgentFixture.requestID) + Data([0x0A])
    }

    /// Counters and the callback are delivered on the main queue, which only runs
    /// while the test lets it: spin until `condition` holds or `timeout` passes.
    private func waitOnMain(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return info.st_mode
    }

    func testDeliversDecodedEventsOnTheMainQueueAndReplies() throws {
        final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var replies: [AgentReply] = []; var onMain = false }
        let box = Box()
        let delivered = expectation(description: "event delivered")
        let server = try startServer { event, reply in
            box.events.append(event)
            box.replies.append(reply)
            box.onMain = Thread.isMainThread
            delivered.fulfill()
        }

        let reply = AgentSocketTestClient.send(line(AgentFixture.preToolUseBash), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
        XCTAssertTrue(box.onMain)
        XCTAssertEqual(box.events.map(\.kind), [.toolStarted])
        XCTAssertEqual(box.events.first?.toolSummary, "Regenerate the project")
        XCTAssertEqual(box.events.first?.host.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(server.receivedCount, 1)
        XCTAssertEqual(server.droppedCount, 0)
        XCTAssertEqual(server.rejectedPeerCount, 0)
        XCTAssertEqual(box.replies.first?.isSettled, true, "a non-permission event is answered by the server itself")
        XCTAssertNil(box.replies.first?.requestID)
    }

    func testCodexLineIsDecodedToo() throws {
        final class Box: @unchecked Sendable { var kinds: [AgentEvent.Kind] = [] }
        let box = Box()
        let delivered = expectation(description: "codex event")
        _ = try startServer { event, _ in box.kinds.append(event.kind); delivered.fulfill() }

        AgentSocketTestClient.send(line(AgentFixture.codexTurnComplete, source: "codex"), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(box.kinds, [.codexTurnComplete])
    }

    func testSocketFileIsASocketOwnedOnlyByTheUser() throws {
        _ = try startServer()
        let mode = try mode(of: socketURL)
        XCTAssertEqual(mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testReplacesAStaleFileAtTheSocketPathAndRefusesADoubleStart() throws {
        try Data("stale".utf8).write(to: socketURL)
        let server = try startServer()
        XCTAssertEqual(try mode(of: socketURL) & S_IFMT, S_IFSOCK)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AgentEventServer.Error, .alreadyStarted)
        }
    }

    func testMessageWithoutTrailingNewlineIsAcceptedAtEOF() throws {
        let delivered = expectation(description: "event")
        _ = try startServer { _, _ in delivered.fulfill() }

        let reply = AgentSocketTestClient.send(AgentFixture.envelope(payload: AgentFixture.stop), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
    }

    func testDropsMalformedEmptyAndOversizedMessages() throws {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = try startServer { _, _ in box.count += 1 }

        AgentSocketTestClient.send("not json\n", to: socketURL.path, replyTimeout: 0)
        AgentSocketTestClient.send(Data(), to: socketURL.path, replyTimeout: 0)
        let padding = String(repeating: "p", count: 70 * 1024)
        AgentSocketTestClient.send(line(AgentFixture.claude("Stop", extra: #""pad":"\#(padding)""#)), to: socketURL.path, replyTimeout: 0)

        XCTAssertTrue(waitOnMain { server.droppedCount == 3 }, "dropped: \(server.droppedCount)")
        XCTAssertEqual(server.receivedCount, 0)
        XCTAssertEqual(box.count, 0)
        // Still serving after the bad clients.
        let delivered = expectation(description: "good event after bad ones")
        let good = try XCTUnwrap(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path))
        XCTAssertEqual(good, #"{"v":1,"decision":null}"#)
        _ = waitOnMain { server.receivedCount == 1 }
        delivered.fulfill()
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(server.receivedCount, 1)
    }

    func testRapidClientsArriveInOrder() throws {
        final class Box: @unchecked Sendable { var ids: [String] = [] }
        let box = Box()
        let server = try startServer { event, _ in box.ids.append(event.sessionID) }
        let expected = (0..<25).map { "s\($0)" }

        // Built up front so the sender thread captures only Sendable values.
        let path = socketURL.path
        let lines = expected.map { line(AgentFixture.claude("UserPromptSubmit", sessionID: $0)) }
        let sender = Thread {
            for data in lines {
                AgentSocketTestClient.send(data, to: path, replyTimeout: 1)
            }
        }
        sender.start()

        XCTAssertTrue(waitOnMain(timeout: 10) { server.receivedCount == expected.count }, "received \(server.receivedCount)")
        XCTAssertEqual(box.ids, expected)
    }

    func testStopRemovesTheSocketFileAndRefusesConnections() throws {
        let server = try startServer()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertNil(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.2))
        // stop() twice is harmless.
        server.stop()
    }

    /// A second instance takes the path over while the first is still running; the
    /// first one quitting must leave the live socket alone.
    func testStopKeepsASocketReboundByAnotherInstance() throws {
        let first = AgentEventServer(socketURL: socketURL) { _, _ in }
        try first.start()
        let second = AgentEventServer(socketURL: socketURL) { _, _ in }
        try second.start()          // unlinks the first file and binds its own
        self.server = second

        first.stop()
        first.stop()                // still idempotent

        XCTAssertEqual(try mode(of: socketURL) & S_IFMT, S_IFSOCK)
        XCTAssertEqual(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path), #"{"v":1,"decision":null}"#)
        XCTAssertTrue(waitOnMain { second.receivedCount == 1 }, "received \(second.receivedCount)")
    }

    /// Same guard for the already-stopped instance: its own stop() removed the file,
    /// a later instance created a new one, and stop() must not remove that one.
    func testStopOfAnAlreadyStoppedInstanceKeepsALaterSocket() throws {
        let first = AgentEventServer(socketURL: socketURL) { _, _ in }
        try first.start()
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))

        let second = AgentEventServer(socketURL: socketURL) { _, _ in }
        try second.start()
        self.server = second

        first.stop()

        XCTAssertEqual(try mode(of: socketURL) & S_IFMT, S_IFSOCK)
        XCTAssertEqual(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path), #"{"v":1,"decision":null}"#)
    }

    func testOverlongPathIsReportedNotBound() {
        let long = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 120) + ".sock")
        let server = AgentEventServer(socketURL: long) { _, _ in }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AgentEventServer.Error, .pathTooLong(long.path.utf8.count))
        }
    }
    // MARK: - Held permission requests (phase 4)

    private final class Held: @unchecked Sendable {
        var events: [AgentEvent] = []
        var replies: [AgentReply] = []
    }

    func testPermissionWithRequestIDIsHeldUntilSend() throws {
        let held = Held()
        _ = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }

        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)
        XCTAssertEqual(held.events.first?.kind, .permissionRequested)
        XCTAssertEqual(reply.requestID, AgentFixture.requestID)
        XCTAssertFalse(reply.isSettled)
        XCTAssertNil(AgentSocketTestClient.readLine(fd, timeout: 0.2), "nothing is written while the request is held")

        reply.send(.allow)

        XCTAssertEqual(AgentSocketTestClient.readLine(fd), #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"allow"}"#)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0, "the server closes after the reply")
        XCTAssertTrue(reply.isSettled)
    }

    func testAHeldPermissionDoesNotDelayAFollowingStop() throws {
        let held = Held()
        let server = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })

        let started = Date()
        let stopReply = AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(stopReply, #"{"v":1,"decision":null}"#)
        XCTAssertLessThan(elapsed, 0.5, "a held connection must not block the next hook; took \(elapsed)s")
        XCTAssertTrue(waitOnMain { server.receivedCount == 2 })
        XCTAssertEqual(held.events.map(\.kind), [.permissionRequested, .stop])
        held.replies.first?.send(nil)
    }

    func testPermissionWithoutRequestIDIsAnsweredImmediately() throws {
        // A pre-2.2 helper (v1 envelope): phase-2 behaviour, nothing is held.
        let held = Held()
        _ = try startServer { event, reply in held.events.append(event); held.replies.append(reply) }
        let v1 = AgentFixture.envelope(payload: AgentFixture.permissionRequestEdit, v: 1) + Data([0x0A])

        let reply = AgentSocketTestClient.send(v1, to: socketURL.path)

        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        XCTAssertEqual(held.events.first?.kind, .permissionRequested)
        XCTAssertNil(held.events.first?.requestID)
        XCTAssertEqual(held.replies.first?.isSettled, true)
    }

    func testSendOnAHeldReplyIsIdempotentOnTheWire() throws {
        let held = Held()
        _ = try startServer { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)

        reply.send(.deny)
        reply.send(.allow)
        reply.send(nil)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var received = Data()
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 1000) > 0 else { break }
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            received.append(buffer, count: count)
        }
        XCTAssertEqual(String(decoding: received, as: UTF8.self),
                       #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":"deny"}"# + "\n",
                       "exactly one reply line, then EOF")
    }

    func testHoldTimeoutAnswersWithNoDecision() throws {
        let held = Held()
        _ = try startServer(holdTimeout: 0.3) { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        defer { close(fd) }
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let started = Date()

        let reply = AgentSocketTestClient.readLine(fd, timeout: 2)

        XCTAssertEqual(reply, #"{"v":2,"request_id":"0123456789abcdef0123456789abcdef","decision":null}"#)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        XCTAssertEqual(held.replies.first?.isSettled, true)
        held.replies.first?.send(.allow)   // late answer after the hold: ignored
    }

    func testAHelperThatLeavesEarlyIsReportedAndItsConnectionReleased() throws {
        let held = Held()
        _ = try startServer { _, reply in held.replies.append(reply) }
        let fd = try XCTUnwrap(AgentSocketTestClient.open(heldLine(), to: socketURL.path))
        XCTAssertTrue(waitOnMain { held.replies.count == 1 })
        let reply = try XCTUnwrap(held.replies.first)
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        reply.onPeerClosed { flag.fired = true }

        close(fd)   // Claude Code killed the helper (old 5 s template), or it crashed

        XCTAssertTrue(waitOnMain { reply.isSettled })
        XCTAssertTrue(flag.fired)
    }

    // MARK: - Peer authentication (spec rule 2)

    func testRejectsAPeerWithAnotherUID() throws {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = try startServer(peerUID: { _ in 0 }) { _, _ in box.count += 1 }   // "root" is not us

        let reply = AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.5)

        XCTAssertNil(reply, "a foreign peer is closed unanswered")
        XCTAssertTrue(waitOnMain { server.rejectedPeerCount == 1 }, "rejected: \(server.rejectedPeerCount)")
        XCTAssertEqual(server.droppedCount, 1, "rejections are part of droppedCount (spec rule 2)")
        XCTAssertEqual(server.receivedCount, 0)
        XCTAssertEqual(box.count, 0)
    }

    func testAPeerWhoseCredentialsCannotBeReadIsRejectedToo() throws {
        let server = try startServer(peerUID: { _ in nil })
        XCTAssertNil(AgentSocketTestClient.send(line(AgentFixture.stop), to: socketURL.path, replyTimeout: 0.5))
        XCTAssertTrue(waitOnMain { server.rejectedPeerCount == 1 })
    }

    func testTheRealPeerCheckAcceptsOurOwnUID() throws {
        // Every other test runs with the real check; this one pins the reason.
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertEqual(AgentEventServer.localPeerUID(fds[0]), getuid())
        XCTAssertNil(AgentEventServer.localPeerUID(-1), "not a socket → no credentials → rejected")
    }
}
