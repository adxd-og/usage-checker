import XCTest
@testable import Omelette

/// Oversized hook payloads whose bulk sits outside `tool_input` (session's design,
/// 2026-11-02, "oversized hook payloads are dropped whole"). Past `maxLineBytes` the
/// helper keeps only the payload keys the app reads (`HookMain.keptPayloadKeys`) and
/// shrinks `tool_input` as before, so a long `last_assistant_message`, `tool_response`,
/// `prompt` or Codex `input-messages` no longer loses the event. Spawns the built
/// `omelette-hook` against a temp `AgentEventServer`, like
/// `OmeletteHookShrinkVerificationTests`.
final class OmeletteHookOversizedPayloadTests: XCTestCase {
    private final class Box: @unchecked Sendable { var events: [AgentEvent] = [] }

    private var socketURL: URL!
    private var server: AgentEventServer?
    private let box = Box()

    /// ~100 KB of a key the app never reads: alone it puts the line past 64 KB.
    private let bulk = String(repeating: "x", count: 100 * 1024)

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

    @discardableResult
    private func runHelper(stdin input: String? = nil, arguments: [String] = []) throws -> Int32 {
        let process = Process()
        process.executableURL = AgentPaths.bundledHelperURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[AgentPaths.socketEnvironmentKey] = socketURL.path
        process.environment = environment
        let stdinPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdinPipe
        try process.run()
        if let input { stdinPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func waitForEvents(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while box.events.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return box.events.count >= count
    }

    private func onlyEvent(file: StaticString = #filePath, line: UInt = #line) throws -> AgentEvent {
        XCTAssertTrue(waitForEvents(1), "the oversized event never reached the app", file: file, line: line)
        XCTAssertEqual(server?.droppedCount, 0, file: file, line: line)
        return try XCTUnwrap(box.events.first, file: file, line: line)
    }

    func testAClaudeStopWithALongLastAssistantMessageArrivesAsStopWithoutAToolSummary() throws {
        try startServer()
        let payload = AgentFixture.claude("Stop", sessionID: "sess-stop", extra: #""last_assistant_message":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.sessionID, "sess-stop")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Usage tracker")
        XCTAssertNil(event.toolSummary, "a shrunk Stop has no tool_input, so it gains no tool summary")
        XCTAssertNil(event.toolDetail, "nor the truncation notice")
    }

    func testAClaudePostToolUseWithALargeToolResponseArrivesAsToolFinishedWithItsSummary() throws {
        try startServer()
        let payload = AgentFixture.claude(
            "PostToolUse",
            extra: #""tool_name":"Read","tool_input":{"file_path":"/tmp/Big.swift"},"tool_response":{"content":"\#(bulk)"}"#
        )

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.kind, .toolFinished)
        XCTAssertEqual(event.toolName, "Read")
        XCTAssertEqual(event.toolSummary, "Read Big.swift")
    }

    func testAClaudeUserPromptSubmitWithALongPromptArrivesAsPromptSubmitted() throws {
        try startServer()
        let payload = AgentFixture.claude("UserPromptSubmit", extra: #""prompt":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertEqual(try onlyEvent().kind, .promptSubmitted)
    }

    func testAnOversizedPermissionPromptNotificationKeepsItsNotificationType() throws {
        try startServer()
        let payload = AgentFixture.claude(
            "Notification",
            extra: #""notification_type":"permission_prompt","message":"\#(bulk)""#
        )

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        XCTAssertEqual(try onlyEvent().kind, .notificationPermission)
    }

    func testASubagentsOversizedEventStaysASubagentEvent() throws {
        try startServer()
        let payload = AgentFixture.claude(
            "Stop",
            extra: #""agent_id":"agent-7","last_assistant_message":"\#(bulk)""#
        )

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.kind, .stop)
        XCTAssertTrue(event.isSubagent)
    }

    func testACodexHookStopWithALongLastAssistantMessageArrivesAsStopFromCodex() throws {
        try startServer()
        let payload = AgentFixture.codexHook("Stop", extra: #""last_assistant_message":"\#(bulk)""#)

        XCTAssertEqual(try runHelper(stdin: payload, arguments: ["--codex-hook"]), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.sessionID, AgentFixture.codexSessionUUID)
        XCTAssertNil(event.toolSummary)
    }

    func testACodexNotifyWithLongInputMessagesArrivesAsATurnComplete() throws {
        try startServer()
        let payload = #"{"type":"agent-turn-complete","thread-id":"thr-big","turn-id":"turn-2","cwd":"/Users/me/Desktop/Orion Gate","input-messages":["\#(bulk)"],"last-assistant-message":"Done."}"#

        XCTAssertEqual(try runHelper(arguments: ["--codex", payload]), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.kind, .codexTurnComplete)
        XCTAssertEqual(event.sessionID, "thr-big")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Orion Gate")
    }

    func testAnOversizedPreToolUseStillShrinksItsToolInput() throws {
        try startServer()
        let payload = AgentFixture.claude(
            "PreToolUse",
            extra: #""tool_name":"Write","tool_input":{"file_path":"/tmp/Notes.txt","content":"\#(bulk)"}"#
        )

        XCTAssertEqual(try runHelper(stdin: payload), 0)
        let event = try onlyEvent()
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.toolSummary, "Write Notes.txt")
        XCTAssertEqual(event.toolDetail, "/tmp/Notes.txt\n" + AgentToolSummary.truncationNotice)
    }
}
