import XCTest
@testable import Omelette

/// Spawns the built `omelette-hook`. The test host is `$(BUILT_PRODUCTS_DIR)/Omelette.app`,
/// so `AgentPaths.bundledHelperURL` (`Bundle.main/Contents/Helpers/omelette-hook`) is the
/// binary the Embed Dependencies phase just copied and signed — no environment lookup needed.
final class OmeletteHookEndToEndTests: XCTestCase {
    private final class Box: @unchecked Sendable { var events: [AgentEvent] = []; var replies: [AgentReply] = [] }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private let box = Box()

    override func setUp() {
        socketURL = AgentFixture.temporarySocketURL()
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: AgentPaths.bundledHelperURL.path),
            "omelette-hook missing at \(AgentPaths.bundledHelperURL.path) — check the OmeletteHook target and the embed dependency in project.yml"
        )
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func startServer() throws {
        let box = self.box
        let server = AgentEventServer(socketURL: socketURL) { event, reply in box.events.append(event); box.replies.append(reply) }
        try server.start()
        self.server = server
    }

    private struct Run {
        let status: Int32
        let stdout: Data
        let elapsed: TimeInterval
    }

    /// Runs the helper against the temp socket with `input` on stdin (or only `arguments`).
    private func runHelper(stdin input: String? = nil, arguments: [String] = []) throws -> Run {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging([AgentPaths.socketEnvironmentKey: socketURL.path]) { $1 }
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        // Read before waiting: waiting on a process whose pipe is full deadlocks.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: output, elapsed: Date().timeIntervalSince(started))
    }

    /// Events arrive on the main queue, which only runs while the test lets it.
    private func waitForEvents(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while box.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.events.count >= count
    }

    func testClaudeStdinPayloadReachesTheServer() throws {
        try startServer()

        let run = try runHelper(stdin: AgentFixture.preToolUseBash)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "the helper must never write to stdout")
        XCTAssertTrue(waitForEvents(1))
        let event = try XCTUnwrap(box.events.first)
        XCTAssertEqual(event.source, .claude)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Usage tracker")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
        XCTAssertFalse(event.isSubagent)
        XCTAssertLessThan(abs(event.receivedAt.timeIntervalSinceNow), 5, "received_at must be the helper's wall clock")
        XCTAssertEqual(server?.receivedCount, 1)
        XCTAssertEqual(server?.droppedCount, 0)
    }

    func testCodexArgvPayloadReachesTheServer() throws {
        try startServer()

        let run = try runHelper(arguments: ["--codex", AgentFixture.codexTurnComplete])

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.source, .codex)
        XCTAssertEqual(box.events.first?.kind, .codexTurnComplete)
        XCTAssertEqual(box.events.first?.sessionID, "thr-9")
        XCTAssertEqual(box.events.first?.cwd, "/Users/me/Desktop/Orion Gate")
    }

    func testEveryClaudeEventRoundTripsInOrder() throws {
        try startServer()
        let cases: [(payload: String, kind: AgentEvent.Kind)] = [
            (AgentFixture.sessionStart, .sessionStart),
            (AgentFixture.userPromptSubmit, .promptSubmitted),
            (AgentFixture.preToolUseBash, .toolStarted),
            (AgentFixture.postToolUseBash, .toolFinished),
            (AgentFixture.permissionRequestEdit, .permissionRequested),
            (AgentFixture.notificationPermission, .notificationPermission),
            (AgentFixture.notificationIdle, .notificationIdle),
            (AgentFixture.stop, .stop),
            (AgentFixture.sessionEnd, .sessionEnd),
            (AgentFixture.subagentPreToolUse, .toolStarted),
        ]

        for entry in cases {
            XCTAssertEqual(try runHelper(stdin: entry.payload).status, 0)
        }

        XCTAssertTrue(waitForEvents(cases.count))
        XCTAssertEqual(box.events.map(\.kind), cases.map(\.kind))
        XCTAssertEqual(box.events.last?.isSubagent, true)
    }

    func testPermissionRequestWaitsForTheReplyAndStaysWithinBudget() throws {
        try startServer()

        let run = try runHelper(stdin: AgentFixture.permissionRequestEdit)

        XCTAssertEqual(run.status, 0)
        XCTAssertLessThan(run.elapsed, 0.8)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .permissionRequested)
        XCTAssertEqual(box.events.first?.toolSummary, "Edit: WalletView.swift")
    }

    func testNoServerMeansExitZeroImmediately() throws {
        // Nothing listens at socketURL — the normal case when Omelette is not running.
        let run = try runHelper(stdin: AgentFixture.stop)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 0.5)
    }

    func testGarbageAndEmptyInputExitZeroWithoutEvents() throws {
        try startServer()

        XCTAssertEqual(try runHelper(stdin: "not json").status, 0)
        XCTAssertEqual(try runHelper(stdin: "").status, 0)
        XCTAssertEqual(try runHelper(stdin: "[1,2,3]").status, 0)
        XCTAssertEqual(try runHelper(arguments: ["--codex"]).status, 0)
        XCTAssertEqual(try runHelper(arguments: ["--codex", "{bad"]).status, 0)

        XCTAssertFalse(waitForEvents(1, timeout: 0.3))
        XCTAssertEqual(server?.receivedCount, 0)
        XCTAssertEqual(server?.droppedCount, 0, "the helper sends nothing it could not parse")
    }

    func testOversizedToolInputIsShrunkNotLost() throws {
        try startServer()
        let content = String(repeating: "z", count: 100 * 1024)
        let payload = AgentFixture.claude(
            "PreToolUse",
            extra: #""tool_name":"Write","tool_input":{"file_path":"/tmp/big.txt","content":"\#(content)"}"#
        )

        XCTAssertEqual(try runHelper(stdin: payload).status, 0)

        XCTAssertTrue(waitForEvents(1))
        XCTAssertEqual(box.events.first?.kind, .toolStarted)
        XCTAssertEqual(box.events.first?.toolSummary, "Write: big.txt")
        XCTAssertEqual(server?.droppedCount, 0)
    }

    func testHostInfoIsWellFormed() throws {
        // Under xcodebuild no known terminal sits above the test host, so the fields may be nil;
        // when present, a pid is a live process with a bundle id and a tty is a /dev path.
        try startServer()

        XCTAssertEqual(try runHelper(stdin: AgentFixture.stop).status, 0)

        XCTAssertTrue(waitForEvents(1))
        let host = try XCTUnwrap(box.events.first?.host)
        if let pid = host.pid {
            XCTAssertEqual(kill(pid, 0), 0, "host pid \(pid) is not alive")
            XCTAssertNotNil(host.bundleID)
        }
        if let tty = host.tty { XCTAssertTrue(tty.hasPrefix("/dev/tty"), tty) }
    }
}
