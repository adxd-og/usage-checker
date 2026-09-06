import XCTest
@testable import Omelette

/// Independent verification of cmux end to end: partial environments on the wire
/// (the executor's `OmeletteHookEndToEndTests` only tries "all three set" and "none
/// set"), the decoder's byte-for-byte pass-through of what the wire actually says,
/// `CmuxRPC`'s escaping on inputs the executor's `CmuxJumpTests` does not try, and
/// `CmuxSocket.send`'s timing guarantees against a socket, not just its boolean result.
final class CmuxVerificationTests: XCTestCase {
    // MARK: - Decoder: an explicit empty string is not the same as an absent key

    func testAnExplicitEmptyCmuxWorkspaceDecodesAsEmptyNotNil() throws {
        // HostProcess.nonEmpty is what turns "" into an absent key on the *write* side;
        // the decoder itself must not silently repeat that filtering, or a future
        // sender that does emit an empty string would have it swallowed invisibly.
        let host = #"{"pid":900,"bundle_id":"com.cmuxterm.app","tty":null,"cmux_workspace":"","cmux_surface":"sf-3","cmux_socket":"/tmp/cmux.sock"}"#
        let event = try AgentEventDecoder.decode(AgentFixture.envelope(payload: #"{"hook_event_name":"Stop","session_id":"sess-1"}"#, host: host))
        XCTAssertEqual(event.host.cmuxWorkspace, "")
        // And SessionActivator.cmuxTarget is where that empty string is finally
        // rejected — confirming the two layers really do divide the work as designed.
        XCTAssertNil(SessionActivator.cmuxTarget(for: event.host))
    }

    // MARK: - CmuxRPC: inputs the executor's CmuxJumpTests does not try

    func testAWorkspaceIDContainingAnEmojiRoundTripsAsValidJSON() {
        // Above U+007F but not a control character: must pass through unescaped, and
        // the line must still be valid, decodable JSON carrying the same string back.
        let lines = CmuxRPC.requests(workspace: "ws-🚀-7", surface: "sf-3")
        let object = try? JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        XCTAssertEqual(params?["workspace"] as? String, "ws-🚀-7")
    }

    func testATabCharacterIsEscapedNotLiteral() {
        let lines = CmuxRPC.requests(workspace: "a\tb", surface: "c")
        XCTAssertTrue(lines[0].contains(#"a\tb"#), lines[0])
        XCTAssertFalse(lines[0].contains("\t"), "a literal tab must not appear unescaped: \(lines[0])")
    }

    func testAnEmptyWorkspaceOrSurfaceStillProducesValidJSON() {
        // CmuxRPC itself has no opinion about emptiness — that veto lives in
        // SessionActivator.cmuxTarget — so an empty string must still round-trip.
        let lines = CmuxRPC.requests(workspace: "", surface: "")
        for line in lines {
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
            XCTAssertNotNil(object, line)
        }
        XCTAssertEqual(lines[0], #"{"id":1,"method":"workspace.select","params":{"workspace":""}}"#)
    }

    // MARK: - CmuxSocket: timing, not just the boolean

    func testAMissingSocketPathFailsInUnderASecond() {
        let start = Date()
        let sent = CmuxSocket.send(lines: ["{}"], to: "/tmp/omelette-verify-no-cmux-\(UUID().uuidString).sock")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(sent)
        XCTAssertLessThan(elapsed, 1.0, "a socket that isn't there must fail fast, not ride out the 0.5s timeout")
    }

    func testALoopbackConnectionRefusedFailsInUnderASecond() throws {
        // A stale socket file with nothing listening behind it: connect() itself
        // returns ECONNREFUSED synchronously — this must not be confused with the
        // EINPROGRESS/poll path that a full backlog would take.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-verify-stale-\(UUID().uuidString.prefix(8)).sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        Darwin.close(fd)   // Bound and immediately closed: the path exists, nothing listens.
        defer { unlink(path) }

        let start = Date()
        let sent = CmuxSocket.send(lines: ["{}"], to: path)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(sent)
        XCTAssertLessThan(elapsed, 1.0, "a refused connection must not wait out the timeout: \(elapsed)s")
    }

    func testALoopbackListenerThatNeverReadsStillSeesTheWriteSucceedQuickly() throws {
        // "The listener that never reads" from the spec's attack list: a small
        // newline-delimited payload fits in the kernel's socket send buffer, so
        // `send` must complete well before the 0.5s timeout even though nothing on
        // the other end ever calls read().
        let listener = try NonReadingUnixListener()
        defer { listener.close() }

        let start = Date()
        let sent = CmuxSocket.send(lines: CmuxRPC.requests(workspace: "ws-7", surface: "sf-3"), to: listener.path)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(sent)
        XCTAssertLessThan(elapsed, 0.5, "a two-line payload must fit in the send buffer without blocking on a reader: \(elapsed)s")
    }
}

/// Accepts one connection and holds it open without ever reading from it — the
/// counterpart to `CmuxJumpTests`' `TestUnixListener`, which actively drains the
/// socket. Same POSIX shape, deliberately smaller (no need to collect bytes).
private final class NonReadingUnixListener: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private var clientFD: Int32 = -1

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-verify-\(UUID().uuidString.prefix(8)).sock").path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "NonReadingUnixListener", code: Int(errno)) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "NonReadingUnixListener", code: Int(errno))
        }

        // Fired off in the background and never awaited here: a Unix-domain
        // `connect()` succeeds once the peer is queued in the listen backlog, before
        // anyone calls `accept()` — so the test's `send()` must not need this to have
        // run first. It exists only so the connection is drained off the backlog
        // instead of sitting there for the length of the test.
        DispatchQueue.global().async { [self] in
            clientFD = accept(fd, nil, nil)
            // Deliberately never read(): the connection is just held open.
        }
    }

    func close() {
        if clientFD >= 0 { Darwin.close(clientFD) }
        Darwin.close(fd)
        unlink(path)
    }
}
