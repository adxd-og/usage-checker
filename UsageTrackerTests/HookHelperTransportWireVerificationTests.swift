import XCTest
@testable import Omelette

/// Independent verification of the helper's wire envelope, at the byte level —
/// below `AgentEventDecoder`. The executor's own `OmeletteHookEndToEndTests` only
/// ever inspects the *decoded* `AgentEvent`; this file runs a raw Unix-socket
/// listener (no `AgentEventServer`, no decoder) so a bug that put `"transport"` on
/// the wire for Claude, or omitted it for a Codex hook, would show up here even if
/// the decoder happened to paper over it.
final class HookHelperTransportWireVerificationTests: XCTestCase {
    private var socketURL: URL!
    private var listenFD: Int32 = -1

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path)"
        )
    }

    override func tearDown() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        try? FileManager.default.removeItem(at: socketURL)
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Data?
        var value: Data? {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func set(_ data: Data) {
            lock.lock(); _value = data; lock.unlock()
        }
    }

    /// Binds a bare Unix domain socket at `socketURL`, spawns the built helper
    /// against it with `input`/`arguments`, and returns exactly what the helper
    /// wrote — untouched by `AgentEventDecoder` or `AgentEventServer`.
    @discardableResult
    private func captureRawLine(stdin input: String?, arguments: [String]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0, "socket() failed: \(errno)")
        listenFD = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                _ = socketURL.path.withCString { strlcpy(buffer, $0, capacity) }
            }
        }
        let boundResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(boundResult, 0, "bind() failed: \(errno)")
        XCTAssertEqual(listen(fd, 1), 0, "listen() failed: \(errno)")

        let captured = Captured()
        let acceptQueue = DispatchQueue(label: "raw-capture")
        acceptQueue.async {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddr, &len)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Read exactly until the line's newline: a held `PermissionRequest`
            // connection never sends an EOF (it is left open, waiting for our
            // decision), so reading to EOF here would deadlock against the helper.
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !data.contains(0x0A) {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
            }
            captured.set(data)
            // If this was a held PermissionRequest, answer it so the helper exits
            // immediately instead of sitting out its (shortened, in-test) timeout.
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
               let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let requestID = object["request_id"] as? String {
                let reply = Data(#"{"v":2,"request_id":"\#(requestID)","decision":"allow"}"#.utf8 + [0x0A])
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            }
            close(client)
        }

        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        environment[AgentPaths.decisionTimeoutEnvironmentKey] = "1"
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(3)
        while captured.value == nil && Date() < deadline { usleep(20_000) }
        let raw = try XCTUnwrap(captured.value, "no bytes captured from the helper within the deadline")
        let line = try XCTUnwrap(String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .newlines), "not valid UTF-8")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            "not a JSON object: \(line)"
        )
        return object
    }

    // MARK: - Claude carries no transport key at all

    func testClaudeStdinEnvelopeHasNoTransportKey() throws {
        let envelope = try captureRawLine(stdin: AgentFixture.preToolUseBash, arguments: [])
        XCTAssertEqual(envelope["source"] as? String, "claude")
        XCTAssertNil(envelope["transport"], "Claude must never put a transport key on the wire")
    }

    // MARK: - Codex notify: transport == "notify", and no request id ever

    func testCodexNotifyEnvelopeIsTaggedNotifyAndNeverCarriesARequestID() throws {
        let envelope = try captureRawLine(stdin: nil, arguments: ["--codex", AgentFixture.codexTurnComplete])
        XCTAssertEqual(envelope["source"] as? String, "codex")
        XCTAssertEqual(envelope["transport"] as? String, "notify")
        XCTAssertNil(envelope["request_id"], "a one-shot notify payload must never be held")
    }

    // MARK: - Codex hook (non-permission): transport == "hook", no request id

    func testCodexHookNonPermissionEnvelopeIsTaggedHookWithNoRequestID() throws {
        let envelope = try captureRawLine(
            stdin: AgentFixture.codexHookPreToolUseBash, arguments: ["--codex-hook"]
        )
        XCTAssertEqual(envelope["source"] as? String, "codex")
        XCTAssertEqual(envelope["transport"] as? String, "hook")
        XCTAssertNil(envelope["request_id"], "only a PermissionRequest hook gets an id")
    }

    // MARK: - Codex hook PermissionRequest: transport == "hook" AND a 32-hex request id

    func testCodexHookPermissionRequestEnvelopeCarriesA32HexRequestID() throws {
        let envelope = try captureRawLine(
            stdin: AgentFixture.codexHookPermissionRequestApplyPatch, arguments: ["--codex-hook"]
        )
        XCTAssertEqual(envelope["source"] as? String, "codex")
        XCTAssertEqual(envelope["transport"] as? String, "hook")
        let requestID = try XCTUnwrap(envelope["request_id"] as? String)
        XCTAssertEqual(requestID.count, 32)
        XCTAssertTrue(requestID.allSatisfy { $0.isHexDigit && !$0.isUppercase }, requestID)
    }

    // MARK: - Claude PermissionRequest still gets a request id despite carrying no transport key

    func testClaudePermissionRequestGetsARequestIDWithNoTransportKey() throws {
        let envelope = try captureRawLine(stdin: AgentFixture.permissionRequestEdit, arguments: [])
        XCTAssertNil(envelope["transport"])
        let requestID = try XCTUnwrap(envelope["request_id"] as? String)
        XCTAssertEqual(requestID.count, 32)
    }
}
