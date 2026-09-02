import XCTest
@testable import Omelette

final class AgentEventDecoderTests: XCTestCase {
    private func decode(_ payload: String, source: String = "claude") throws -> AgentEvent {
        try AgentEventDecoder.decode(AgentFixture.envelope(source: source, payload: payload))
    }

    // MARK: Claude events

    func testSessionStart() throws {
        let event = try decode(AgentFixture.sessionStart)
        XCTAssertEqual(event.source, .claude)
        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Usage tracker")
        XCTAssertNil(event.toolName)
        XCTAssertNil(event.toolSummary)
        XCTAssertFalse(event.isSubagent)
        XCTAssertEqual(event.host, AgentHostInfo(pid: 4242, bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004"))
        XCTAssertEqual(event.receivedAt.timeIntervalSince1970, 1_756_800_000.123, accuracy: 0.001)
    }

    func testUserPromptSubmit() throws {
        XCTAssertEqual(try decode(AgentFixture.userPromptSubmit).kind, .promptSubmitted)
    }

    func testPreToolUseCarriesTheToolSummary() throws {
        let event = try decode(AgentFixture.preToolUseBash)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
    }

    func testPostToolUse() throws {
        let event = try decode(AgentFixture.postToolUseBash)
        XCTAssertEqual(event.kind, .toolFinished)
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolSummary, "Bash: xcodegen generate")
    }

    func testPermissionRequest() throws {
        let event = try decode(AgentFixture.permissionRequestEdit)
        XCTAssertEqual(event.kind, .permissionRequested)
        XCTAssertEqual(event.toolSummary, "Edit: WalletView.swift")
    }

    func testNotificationVariants() throws {
        XCTAssertEqual(try decode(AgentFixture.notificationPermission).kind, .notificationPermission)
        XCTAssertEqual(try decode(AgentFixture.notificationIdle).kind, .notificationIdle)
        XCTAssertEqual(try decode(AgentFixture.notificationOther).kind, .unknown("Notification:auth_success"))
    }

    func testStopAndSessionEnd() throws {
        XCTAssertEqual(try decode(AgentFixture.stop).kind, .stop)
        XCTAssertEqual(try decode(AgentFixture.sessionEnd).kind, .sessionEnd)
    }

    func testSubagentEventsAreFlagged() throws {
        let event = try decode(AgentFixture.subagentPreToolUse)
        XCTAssertTrue(event.isSubagent)
        XCTAssertEqual(event.kind, .toolStarted)
        XCTAssertEqual(event.toolSummary, "Grep: AgentEvent")
    }

    func testUnknownHookEventKeepsItsName() throws {
        XCTAssertEqual(try decode(AgentFixture.unknownEvent).kind, .unknown("SubagentStop"))
    }

    // MARK: Codex

    func testCodexTurnComplete() throws {
        let event = try decode(AgentFixture.codexTurnComplete, source: "codex")
        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.kind, .codexTurnComplete)
        XCTAssertEqual(event.sessionID, "thr-9")
        XCTAssertEqual(event.cwd, "/Users/me/Desktop/Orion Gate")
        XCTAssertNil(event.toolName)
        XCTAssertFalse(event.isSubagent)
    }

    func testCodexUnknownType() throws {
        let event = try decode(#"{"type":"agent-approval-needed","thread-id":"thr-9"}"#, source: "codex")
        XCTAssertEqual(event.kind, .unknown("agent-approval-needed"))
    }

    // MARK: Envelope validation

    func testNullHostFieldsDecodeAsNil() throws {
        let data = AgentFixture.envelope(payload: AgentFixture.stop, host: #"{"pid":null,"bundle_id":null,"tty":null}"#)
        XCTAssertEqual(try AgentEventDecoder.decode(data).host, .none)
        let missing = Data(#"{"v":1,"source":"claude","helper_version":1,"received_at":1,"payload":\#(AgentFixture.stop)}"#.utf8)
        XCTAssertEqual(try AgentEventDecoder.decode(missing).host, .none)
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try AgentEventDecoder.decode(Data("not json\n".utf8))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .notJSON)
        }
        XCTAssertThrowsError(try AgentEventDecoder.decode(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .notJSON)
        }
    }

    func testRejectsOtherWireVersions() {
        XCTAssertThrowsError(try AgentEventDecoder.decode(AgentFixture.envelope(payload: AgentFixture.stop, v: 2))) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .unsupportedVersion(2))
        }
        let noVersion = Data(#"{"source":"claude","payload":\#(AgentFixture.stop)}"#.utf8)
        XCTAssertThrowsError(try AgentEventDecoder.decode(noVersion)) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .missingField("v"))
        }
    }

    func testRejectsMissingFields() {
        func assertMissing(_ data: Data, _ field: String, line: UInt = #line) {
            XCTAssertThrowsError(try AgentEventDecoder.decode(data), line: line) { error in
                XCTAssertEqual(error as? AgentEventDecoder.Error, .missingField(field), line: line)
            }
        }
        assertMissing(Data(#"{"v":1,"payload":{}}"#.utf8), "source")
        assertMissing(AgentFixture.envelope(source: "gemini", payload: AgentFixture.stop), "source")
        assertMissing(Data(#"{"v":1,"source":"claude"}"#.utf8), "payload")
        assertMissing(AgentFixture.envelope(payload: #"{"session_id":"s","cwd":"/x"}"#), "hook_event_name")
        assertMissing(AgentFixture.envelope(payload: #"{"hook_event_name":"Stop","cwd":"/x"}"#), "session_id")
        assertMissing(AgentFixture.envelope(payload: #"{"hook_event_name":"Stop","session_id":""}"#), "session_id")
        assertMissing(AgentFixture.envelope(source: "codex", payload: #"{"thread-id":"t"}"#), "type")
        assertMissing(AgentFixture.envelope(source: "codex", payload: #"{"type":"agent-turn-complete"}"#), "thread-id")
    }

    func testRejectsLinesOver64KB() {
        let padding = String(repeating: "p", count: 64 * 1024)
        let big = AgentFixture.envelope(payload: AgentFixture.claude("Stop", extra: #""pad":"\#(padding)""#))
        XCTAssertGreaterThan(big.count, AgentEventDecoder.maxLineBytes)
        XCTAssertThrowsError(try AgentEventDecoder.decode(big)) { error in
            XCTAssertEqual(error as? AgentEventDecoder.Error, .tooLarge)
        }
        // Exactly at the cap is fine: pad a valid envelope with trailing spaces (JSON allows them).
        var atCap = AgentFixture.envelope(payload: AgentFixture.stop)
        atCap.append(Data(String(repeating: " ", count: AgentEventDecoder.maxLineBytes - atCap.count).utf8))
        XCTAssertEqual(atCap.count, AgentEventDecoder.maxLineBytes)
        XCTAssertNoThrow(try AgentEventDecoder.decode(atCap))
    }
}
