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

    private struct Launched {
        let process: Process
        let stdout: Pipe
        let started: Date
    }

    static let allowJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"# + "\n"
    static let denyJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"# + "\n"

    /// Starts the helper against the temp socket with `input` on stdin (or only `arguments`).
    /// `decisionTimeout` sets OMELETTE_DECISION_TIMEOUT (seconds) — the helper honours it
    /// only because the socket override is in the temp dir.
    private func launchHelper(stdin input: String? = nil, arguments: [String] = [], decisionTimeout: TimeInterval? = nil) throws -> Launched {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        if let decisionTimeout { environment[AgentPaths.decisionTimeoutEnvironmentKey] = String(decisionTimeout) }
        process.environment = environment
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        return Launched(process: process, stdout: stdout, started: started)
    }

    /// Drains stdout (the helper writes at most one short line, so the pipe never
    /// fills) and waits for exit.
    private func finish(_ launched: Launched) -> Run {
        let output = launched.stdout.fileHandleForReading.readDataToEndOfFile()
        launched.process.waitUntilExit()
        return Run(status: launched.process.terminationStatus, stdout: output, elapsed: Date().timeIntervalSince(launched.started))
    }

    /// Fire-and-forget events: launch and finish in one go.
    private func runHelper(stdin input: String? = nil, arguments: [String] = [], decisionTimeout: TimeInterval? = nil) throws -> Run {
        finish(try launchHelper(stdin: input, arguments: arguments, decisionTimeout: decisionTimeout))
    }

    /// The reply handle of the `count`-th event, once the server has delivered it on main.
    private func waitForReply(_ count: Int = 1, timeout: TimeInterval = 2) -> AgentReply? {
        guard waitForEvents(count, timeout: timeout) else { return nil }
        return box.replies[count - 1]
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
            XCTAssertEqual(try runHelper(stdin: entry.payload, decisionTimeout: 0.2).status, 0)
        }

        XCTAssertTrue(waitForEvents(cases.count))
        XCTAssertEqual(box.events.map(\.kind), cases.map(\.kind))
        XCTAssertEqual(box.events.last?.isSubagent, true)
    }

    // MARK: - PermissionRequest decisions (spec rules 1, 3, 5)

    func testAllowIsPrintedExactlyAsClaudeExpectsIt() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)

        let reply = try XCTUnwrap(waitForReply())
        XCTAssertEqual(box.events.first?.kind, .permissionRequested)
        XCTAssertEqual(box.events.first?.toolSummary, "Edit: WalletView.swift")
        XCTAssertEqual(reply.requestID?.count, 32)
        XCTAssertEqual(box.events.first?.requestID, reply.requestID)
        XCTAssertFalse(reply.isSettled)
        reply.send(.allow)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.allowJSON)
        XCTAssertLessThan(run.elapsed, 3)
    }

    func testDenyIsPrintedExactlyAsClaudeExpectsIt() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(.deny)

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.denyJSON)
    }

    func testNoDecisionPrintsNothingAndExitsZeroWithinItsBudget() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 0.5)
        let reply = try XCTUnwrap(waitForReply())
        // The app says nothing: the helper must give up on its own.
        let run = finish(launched)

        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "no decision → no output: \(String(decoding: run.stdout, as: UTF8.self))")
        XCTAssertGreaterThanOrEqual(run.elapsed, 0.45)
        XCTAssertLessThan(run.elapsed, 1.5)
        XCTAssertTrue(waitOnMainUntil { reply.isSettled }, "the server saw the helper leave")
    }

    func testNullDecisionFromTheAppPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(nil)   // presence release / expiry

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 2)
    }

    func testAReplyWithAnotherRequestIDPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
        let reply = try XCTUnwrap(waitForReply())
        XCTAssertNotEqual(reply.requestID, AgentFixture.requestID)
        reply.sendRaw(AgentReply.line(requestID: AgentFixture.requestID, decision: .allow))   // forged: someone else's id

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty, "an allow for a foreign id must never reach Claude")
    }

    func testMalformedRepliesPrintNothing() throws {
        try startServer()
        let forged: [Data] = [
            Data("not json\n".utf8),
            Data("{\"v\":2,\"decision\":\"allow\"}\n".utf8),                         // no request_id
            Data("{\"v\":2,\"request_id\":\"".utf8) + Data("X".utf8) + Data("\",\"decision\":\"allow\"}\n".utf8),
            Data("[\"allow\"]\n".utf8),
        ]
        for line in forged {
            let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
            let reply = try XCTUnwrap(waitForReply(box.events.count + 1))
            reply.sendRaw(line)
            let run = finish(launched)
            XCTAssertEqual(run.status, 0)
            XCTAssertTrue(run.stdout.isEmpty, "printed for \(String(decoding: line, as: UTF8.self))")
        }
    }

    func testADecisionOtherThanAllowOrDenyPrintsNothing() throws {
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1)
        let reply = try XCTUnwrap(waitForReply())
        let id = try XCTUnwrap(reply.requestID)
        reply.sendRaw(Data("{\"v\":2,\"request_id\":\"\(id)\",\"decision\":\"maybe\"}\n".utf8))

        let run = finish(launched)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
    }

    func testEachPermissionRequestGetsAFreshID() throws {
        try startServer()
        let first = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let firstReply = try XCTUnwrap(waitForReply(1))
        let second = try launchHelper(stdin: AgentFixture.permissionRequestEdit)
        let secondReply = try XCTUnwrap(waitForReply(2))
        XCTAssertNotEqual(firstReply.requestID, secondReply.requestID)
        firstReply.send(nil)
        secondReply.send(nil)
        _ = finish(first)
        _ = finish(second)
    }

    func testOtherEventsStillNeverWaitAndNeverPrint() throws {
        try startServer()
        let run = try runHelper(stdin: AgentFixture.preToolUseBash)
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.stdout.isEmpty)
        XCTAssertLessThan(run.elapsed, 0.8)
        XCTAssertTrue(waitForEvents(1))
        XCTAssertNil(box.events.first?.requestID, "only a PermissionRequest carries an id")
    }

    func testTheTimeoutOverrideCannotLengthenTheWait() throws {
        // OMELETTE_DECISION_TIMEOUT is clamped to the production 140 s; a huge value
        // must not turn into a longer hold. Observable here only as "still exits when
        // the app answers", so the assertion is on the answer path, not on 140 s.
        try startServer()
        let launched = try launchHelper(stdin: AgentFixture.permissionRequestEdit, decisionTimeout: 1_000_000)
        let reply = try XCTUnwrap(waitForReply())
        reply.send(.allow)
        let run = finish(launched)
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), Self.allowJSON)
    }

    private func waitOnMainUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
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
