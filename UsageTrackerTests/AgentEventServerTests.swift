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

    private func startServer(onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in }) throws -> AgentEventServer {
        let server = AgentEventServer(socketURL: socketURL, onEvent: onEvent)
        try server.start()
        self.server = server
        return server
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
        final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var onMain = false }
        let box = Box()
        let delivered = expectation(description: "event delivered")
        let server = try startServer { event in
            box.events.append(event)
            box.onMain = Thread.isMainThread
            delivered.fulfill()
        }

        let reply = AgentSocketTestClient.send(line(AgentFixture.preToolUseBash), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
        XCTAssertTrue(box.onMain)
        XCTAssertEqual(box.events.map(\.kind), [.toolStarted])
        XCTAssertEqual(box.events.first?.toolSummary, "Bash: xcodegen generate")
        XCTAssertEqual(box.events.first?.host.bundleID, "com.googlecode.iterm2")
        XCTAssertEqual(server.receivedCount, 1)
        XCTAssertEqual(server.droppedCount, 0)
    }

    func testCodexLineIsDecodedToo() throws {
        final class Box: @unchecked Sendable { var kinds: [AgentEvent.Kind] = [] }
        let box = Box()
        let delivered = expectation(description: "codex event")
        _ = try startServer { event in box.kinds.append(event.kind); delivered.fulfill() }

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
        _ = try startServer { _ in delivered.fulfill() }

        let reply = AgentSocketTestClient.send(AgentFixture.envelope(payload: AgentFixture.stop), to: socketURL.path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(reply, #"{"v":1,"decision":null}"#)
    }

    func testDropsMalformedEmptyAndOversizedMessages() throws {
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let server = try startServer { _ in box.count += 1 }

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
        let server = try startServer { event in box.ids.append(event.sessionID) }
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

    func testOverlongPathIsReportedNotBound() {
        let long = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 120) + ".sock")
        let server = AgentEventServer(socketURL: long) { _ in }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AgentEventServer.Error, .pathTooLong(long.path.utf8.count))
        }
    }
}
