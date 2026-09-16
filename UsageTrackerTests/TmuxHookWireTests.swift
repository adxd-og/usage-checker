import XCTest
@testable import Omelette

/// The hook's half of the tmux jump: what an `omelette-hook` started inside a tmux
/// pane puts in the envelope's `host` object. Spec:
/// docs/superpowers/specs/2026-09-17-tmux-jump-design.md, "Hook".
///
/// `HostProcess` lives only in the `OmeletteHook` target and cannot be imported here,
/// so — like `OmeletteHookEndToEndTests` — this spawns the real built binary with an
/// injected environment and reads what reaches the socket. The last test reads the
/// raw bytes, because "absent" and "null" decode to the same nil.
final class TmuxHookWireTests: XCTestCase {
    private final class Box: @unchecked Sendable { var events: [AgentEvent] = [] }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private let box = Box()

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path)"
        )
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func startServer() throws {
        let box = self.box
        let server = AgentEventServer(socketURL: socketURL) { event, _ in box.events.append(event) }
        try server.start()
        self.server = server
    }

    /// Runs the helper with exactly the tmux variables given. Both are cleared first,
    /// so a tester who happens to run the suite inside tmux still gets a clean case.
    @discardableResult
    private func runHelper(tmux: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        for key in ["TMUX", "TMUX_PANE"] { environment.removeValue(forKey: key) }
        for (key, value) in tmux { environment[key] = value }
        process.environment = environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(AgentFixture.stop.utf8))
        try stdin.fileHandleForWriting.close()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func waitForEvents(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while box.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.events.count >= count
    }

    /// `proc_pidpath` of our own pid — the same answer the helper gets for the pid we
    /// put in `$TMUX`, without assuming anything about where the runner lives.
    private func ownExecutablePath() throws -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        XCTAssertGreaterThan(length, 0, "proc_pidpath on our own pid")
        return String(decoding: buffer[..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func testAPaneEnvironmentReachesTheAppAsATmuxAddress() throws {
        try startServer()
        let expected = try ownExecutablePath()

        XCTAssertEqual(try runHelper(tmux: [
            "TMUX": "/private/tmp/tmux-501/default,\(getpid()),0",
            "TMUX_PANE": "%3",
        ]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertEqual(host.tmuxSocket, "/private/tmp/tmux-501/default")
        XCTAssertEqual(host.tmuxPane, "%3")
        XCTAssertEqual(host.tmuxBinary, expected, "tmux_bin is proc_pidpath of the server pid in $TMUX")
    }

    func testWithoutTmuxInTheEnvironmentTheKeysAreAbsent() throws {
        try startServer()

        XCTAssertEqual(try runHelper(tmux: [:]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertNil(host.tmuxSocket)
        XCTAssertNil(host.tmuxPane)
        XCTAssertNil(host.tmuxBinary)
    }

    func testHalfATmuxEnvironmentIsNoAddressAtAll() throws {
        try startServer()

        XCTAssertEqual(try runHelper(tmux: ["TMUX": "/private/tmp/tmux-501/default,\(getpid()),0"]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertNil(host.tmuxSocket, "no TMUX_PANE, so there is no pane to jump to")
        XCTAssertNil(host.tmuxPane)
        XCTAssertNil(host.tmuxBinary)
    }

    func testAServerThatIsGoneStillCarriesTheSocketAndThePane() throws {
        // proc_pidpath fails for a pid that does not exist; the address is still worth
        // sending, and the app falls back to tmux's usual install paths.
        try startServer()

        XCTAssertEqual(try runHelper(tmux: [
            "TMUX": "/private/tmp/tmux-501/default,2147483646,0",
            "TMUX_PANE": "%0",
        ]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertEqual(host.tmuxSocket, "/private/tmp/tmux-501/default")
        XCTAssertEqual(host.tmuxPane, "%0")
        XCTAssertNil(host.tmuxBinary)
    }

    /// Below the decoder: "absent" and "null" both decode to nil, and only one of
    /// them is the contract.
    func testTheRawEnvelopeOmitsTheTmuxKeysRatherThanNullingThem() throws {
        let listener = try RawLineListener()
        defer { listener.close() }

        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = listener.path
        for key in ["TMUX", "TMUX_PANE"] { environment.removeValue(forKey: key) }
        process.environment = environment
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(AgentFixture.stop.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let line = try XCTUnwrap(listener.wait(timeout: 3), "no bytes captured from the helper")
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line
        )
        let host = try XCTUnwrap(envelope["host"] as? [String: Any])
        XCTAssertNil(host["tmux_socket"], "an absent address is an absent key, never null: \(host)")
        XCTAssertNil(host["tmux_pane"], "\(host)")
        XCTAssertNil(host["tmux_bin"], "\(host)")
        XCTAssertEqual(envelope["v"] as? Int, 2, "three optional keys do not bump the wire version")
    }
}

/// A one-shot AF_UNIX listener that accepts one connection and returns the first
/// newline-terminated line, untouched by `AgentEventServer` or the decoder.
private final class RawLineListener: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let semaphore = DispatchSemaphore(value: 0)
    private var received: String?

    init() throws {
        path = AgentFixture.temporarySocketURL().path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "RawLineListener", code: Int(errno)) }

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
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "RawLineListener", code: Int(errno))
        }

        DispatchQueue.global().async { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { semaphore.signal(); return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !data.contains(0x0A) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
            }
            Darwin.close(client)
            received = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
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
