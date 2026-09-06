import XCTest
@testable import Omelette

/// Jumping to a cmux tab: the two JSON-RPC lines, the address they are built from,
/// and the socket write itself against a real listener.
final class CmuxJumpTests: XCTestCase {
    // MARK: - CmuxRPC

    func testTheTwoRequestsAreTheOnesCmuxAnswers() {
        XCTAssertEqual(
            CmuxRPC.requests(workspace: "ws-7", surface: "sf-3"),
            [
                #"{"id":1,"method":"workspace.select","params":{"workspace":"ws-7"}}"#,
                #"{"id":2,"method":"surface.focus","params":{"surface":"sf-3"}}"#,
            ]
        )
    }

    func testTheWorkspaceIsSelectedBeforeTheSurfaceIsFocused() {
        let lines = CmuxRPC.requests(workspace: "a", surface: "b")
        XCTAssertTrue(lines[0].contains("workspace.select"))
        XCTAssertTrue(lines[1].contains("surface.focus"))
        XCTAssertTrue(lines[0].contains(#""id":1"#))
        XCTAssertTrue(lines[1].contains(#""id":2"#))
    }

    func testAnIDCannotWriteAThirdRequest() {
        // The ids come off a shell environment variable. A quote in one must close
        // nothing; a newline must not split the line in two.
        let lines = CmuxRPC.requests(workspace: "ws\"7", surface: "sf\n3")
        XCTAssertEqual(lines[0], #"{"id":1,"method":"workspace.select","params":{"workspace":"ws\"7"}}"#)
        XCTAssertEqual(lines[1], #"{"id":2,"method":"surface.focus","params":{"surface":"sf\n3"}}"#)
        for line in lines {
            XCTAssertFalse(line.contains("\n"), "a literal newline would be two messages: \(line)")
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(object ?? nil, "still valid JSON: \(line)")
        }
    }

    func testBackslashesAndControlCharactersAreEscaped() {
        let lines = CmuxRPC.requests(workspace: "a\\b", surface: "c\u{01}d")
        XCTAssertTrue(lines[0].contains(#"a\\b"#), lines[0])
        XCTAssertTrue(lines[1].contains(#"c\u0001d"#), lines[1])
    }

    // MARK: - SessionActivator.cmuxTarget

    private func host(workspace: String?, surface: String?, socket: String?) -> AgentHostInfo {
        AgentHostInfo(pid: 900, bundleID: "com.cmuxterm.app", tty: nil,
                      cmuxWorkspace: workspace, cmuxSurface: surface, cmuxSocket: socket)
    }

    func testAFullAddressIsACmuxTarget() {
        XCTAssertEqual(
            SessionActivator.cmuxTarget(for: host(workspace: "ws-7", surface: "sf-3", socket: "/tmp/x.sock")),
            SessionActivator.CmuxTarget(workspace: "ws-7", surface: "sf-3", socketPath: "/tmp/x.sock")
        )
    }

    func testAMissingSocketPathFallsBackToCmuxsDefault() {
        XCTAssertEqual(
            SessionActivator.cmuxTarget(for: host(workspace: "ws-7", surface: "sf-3", socket: nil))?.socketPath,
            "/tmp/cmux.sock"
        )
        XCTAssertEqual(
            SessionActivator.cmuxTarget(for: host(workspace: "ws-7", surface: "sf-3", socket: ""))?.socketPath,
            CmuxSocket.defaultPath
        )
    }

    func testHalfAnAddressIsNoTarget() {
        XCTAssertNil(SessionActivator.cmuxTarget(for: host(workspace: "ws-7", surface: nil, socket: nil)))
        XCTAssertNil(SessionActivator.cmuxTarget(for: host(workspace: nil, surface: "sf-3", socket: nil)))
        XCTAssertNil(SessionActivator.cmuxTarget(for: host(workspace: "", surface: "sf-3", socket: nil)))
    }

    func testANormalTerminalIsNeverACmuxTarget() {
        XCTAssertNil(SessionActivator.cmuxTarget(
            for: AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        ))
        XCTAssertNil(SessionActivator.cmuxTarget(for: .none))
    }

    // MARK: - CmuxSocket, against a real listener

    func testBothLinesReachAListeningSocket() throws {
        let listener = try TestUnixListener()
        defer { listener.close() }

        XCTAssertTrue(CmuxSocket.send(lines: CmuxRPC.requests(workspace: "ws-7", surface: "sf-3"),
                                      to: listener.path))

        let received = try XCTUnwrap(listener.wait(timeout: 2))
        XCTAssertEqual(
            received,
            #"{"id":1,"method":"workspace.select","params":{"workspace":"ws-7"}}"# + "\n" +
            #"{"id":2,"method":"surface.focus","params":{"surface":"sf-3"}}"# + "\n",
            "newline-delimited, in order, one write"
        )
    }

    func testNothingListeningIsNotAnError() {
        // cmux not running is the normal case for everyone who does not use it.
        XCTAssertFalse(CmuxSocket.send(lines: ["{}"], to: "/tmp/omelette-no-such-cmux-\(UUID().uuidString).sock"))
    }

    func testNoLinesIsANoOp() {
        XCTAssertFalse(CmuxSocket.send(lines: [], to: CmuxSocket.defaultPath))
    }

    func testAnImpossiblySocketPathIsRefusedRatherThanTruncated() {
        // sun_path holds 103 bytes; a longer path would be silently cut and could
        // name someone else's socket.
        XCTAssertFalse(CmuxSocket.send(lines: ["{}"], to: "/tmp/" + String(repeating: "x", count: 200) + ".sock"))
    }
}

/// A one-shot AF_UNIX listener: accepts a single connection, reads until EOF and
/// hands the bytes back. The same POSIX shape `AgentEventServer` uses, small enough
/// to keep in the test that needs it.
private final class TestUnixListener: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let semaphore = DispatchSemaphore(value: 0)
    private var received = ""

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(UUID().uuidString.prefix(8)).sock").path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "TestUnixListener", code: Int(errno)) }

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
            throw NSError(domain: "TestUnixListener", code: Int(errno))
        }

        DispatchQueue.global().async { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { semaphore.signal(); return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var text = ""
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                text += String(decoding: buffer[0..<count], as: UTF8.self)
            }
            Darwin.close(client)
            received = text
            semaphore.signal()
        }
    }

    func wait(timeout: TimeInterval) -> String? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return received
    }

    func close() {
        Darwin.close(fd)
        unlink(path)
    }
}
