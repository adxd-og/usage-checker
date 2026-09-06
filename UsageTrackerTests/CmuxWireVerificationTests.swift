import XCTest
@testable import Omelette

/// Independent, end-to-end verification of one exact gap in the spec's cmux attack
/// list: "env with only CMUX_WORKSPACE_ID (no surface) → what goes on the wire".
/// `HostProcess` (which reads the three CMUX_* variables) lives only in the
/// `HookHelper` target and cannot be imported here, so — like the executor's own
/// `OmeletteHookEndToEndTests` — this spawns the real built `omelette-hook` binary
/// and inspects what actually reaches the app's socket.
final class CmuxWireVerificationTests: XCTestCase {
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

    /// Launches the helper with only the given cmux variables set (any of the three
    /// left out of `cmux` is genuinely absent from the child's environment, not set
    /// to an empty string), waits for it to exit, and returns its status.
    @discardableResult
    private func runHelper(cmux: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        for key in ["CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH"] { environment.removeValue(forKey: key) }
        for (key, value) in cmux { environment[key] = value }
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

    func testOnlyTheWorkspaceIDInTheEnvironmentPutsOnlyThatKeyOnTheWire() throws {
        try startServer()

        XCTAssertEqual(try runHelper(cmux: ["CMUX_WORKSPACE_ID": "ws-only"]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertEqual(host.cmuxWorkspace, "ws-only")
        XCTAssertNil(host.cmuxSurface, "no CMUX_SURFACE_ID was exported, so no surface id must appear")
        XCTAssertNil(host.cmuxSocket, "no CMUX_SOCKET_PATH was exported, so no socket path must appear")
    }

    func testOnlyTheSurfaceIDInTheEnvironmentPutsOnlyThatKeyOnTheWire() throws {
        try startServer()

        XCTAssertEqual(try runHelper(cmux: ["CMUX_SURFACE_ID": "sf-only"]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertNil(host.cmuxWorkspace)
        XCTAssertEqual(host.cmuxSurface, "sf-only")
        XCTAssertNil(host.cmuxSocket)
    }

    func testAnEmptyStringWorkspaceIDIsTreatedAsUnsetOnTheWire() throws {
        // HostProcess.nonEmpty: "an exported-but-empty variable says as little as an
        // unset one" — a shell that exports CMUX_WORKSPACE_ID="" (rather than not
        // exporting it) must still produce an envelope with no cmux_workspace key.
        try startServer()

        XCTAssertEqual(try runHelper(cmux: ["CMUX_WORKSPACE_ID": "", "CMUX_SURFACE_ID": "sf-3"]), 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        XCTAssertNil(host.cmuxWorkspace, "an empty exported value must be omitted, same as absent")
        XCTAssertEqual(host.cmuxSurface, "sf-3")
    }
}
