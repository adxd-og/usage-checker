import XCTest
@testable import Omelette

/// The JSON-RPC surface, byte for byte. Goldens rather than dictionary walks: an MCP
/// client parses these strings, and a key that quietly changes name is exactly the bug
/// a structural assertion would sail past.
final class MCPServerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func handle(_ line: String, snapshot: StatusSnapshot? = nil) -> String? {
        MCPServer.handle(line, snapshot: snapshot, now: now)
    }

    // MARK: - Lifecycle

    func testInitializeAnswersWithToolsAndOurIdentity() {
        let response = handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.90"}}}"#)

        XCTAssertEqual(response, #"{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"instructions":"\#(MCPServer.instructions)","protocolVersion":"2025-06-18","serverInfo":{"name":"omelette","version":"\#(CLIText.version)"}}}"#)
    }

    /// Where the answers come from and when they are an error, as the code does it: the
    /// last snapshot on disk, stale or not, and an error result only without one.
    func testTheInstructionsSayWhereTheAnswersComeFrom() {
        XCTAssertEqual(MCPServer.instructions, "Omelette answers from the snapshot the menu-bar app last wrote (updatedAt in every answer), not from a live fetch. After the app quits, the tools keep answering from its last snapshot and say so once it is more than ten minutes old; every tool returns an error result when there is no snapshot to read. get_usage: rate-limit windows and cost per provider, worth a call before long or expensive work. get_agents: whether another session is waiting for the user. get_sessions: recent chats with token and cost totals.")
    }

    func testAVersionWeKnowIsEchoedAndAnythingElseGetsOurs() {
        for version in MCPServer.supportedProtocolVersions {
            let response = handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#)
            XCTAssertTrue(response?.contains("\"protocolVersion\":\"\(version)\"") == true, version)
        }
        // The 2026 revision dropped the handshake entirely; answering with a version we
        // do speak is what the spec asks for, and the client decides from there.
        let future = handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#)
        XCTAssertTrue(future?.contains("\"protocolVersion\":\"2025-06-18\"") == true, future ?? "nil")

        let none = handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertTrue(none?.contains("\"protocolVersion\":\"2025-06-18\"") == true, none ?? "nil")
    }

    func testANotificationIsAnsweredWithNothing() {
        XCTAssertNil(handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
    }

    func testPingIsAnEmptyResult() {
        XCTAssertEqual(handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#), #"{"id":2,"jsonrpc":"2.0","result":{}}"#)
    }

    // MARK: - tools/list

    func testToolsListIsTheGoldenSchema() {
        let response = handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)

        XCTAssertEqual(response, #"{"id":4,"jsonrpc":"2.0","result":{"tools":[{"description":"Every provider Omelette tracks (Claude, Codex, Antigravity, Grok, and Anthropic Enterprise when an Admin API key is set): each rate-limit window's percent used and when it resets, today's and this week's cost, and whether those dollars are an API-list-price equivalent of local CLI usage rather than the subscription bill. Read from the app's last snapshot; updatedAt says how old it is, and a provider that is closed or signed out keeps its last-known numbers, marked retained, with its state. Returns an error result when there is no snapshot to read. Use it before starting long or expensive work; it does not start a refresh.","inputSchema":{"additionalProperties":false,"properties":{},"type":"object"},"name":"get_usage","title":"AI usage right now"},{"description":"The live Claude Code and Codex sessions Omelette can see: how many need a decision from the user, how many are working, and per session its project, state (needs you, working, done, idle) and current activity. Sessions come through the Omelette hooks; a session without them is read from its CLI's log while it has been active in the last 30 minutes, approximately, and never shows as needing the user. Read from the app's last snapshot (updatedAt); returns an error result when there is no snapshot to read. Use it to learn whether another session is blocked on the user before starting work that needs them.","inputSchema":{"additionalProperties":false,"properties":{},"type":"object"},"name":"get_agents","title":"Agent sessions right now"},{"description":"The recent Claude Code and Codex chats Omelette can see, newest first: what each one is called, the project it ran in, when it was last active, its turns, tokens and cost (where apiEquivalent is true, an API-list-price equivalent rather than the subscription bill), and how many sub-agents it launched. provider narrows to one CLI; limit caps the list at 15. Read from the app's last snapshot; returns an error result when there is no snapshot to read. It does not return transcripts or per-turn detail.","inputSchema":{"additionalProperties":false,"properties":{"limit":{"description":"How many chats to list. Default 10, maximum 15.","maximum":15,"minimum":1,"type":"integer"},"provider":{"description":"Only this provider's chats: claude or codex. Omit for both.","enum":["claude","codex"],"type":"string"}},"type":"object"},"name":"get_sessions","title":"Recent chats"}]}}"#)
    }

    func testToolsListIgnoresACursorRatherThanFailing() {
        // Two tools never paginate, but a client is allowed to send one.
        let response = handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"cursor":"x"}}"#)
        XCTAssertTrue(response?.contains("\"name\":\"get_usage\"") == true)
        XCTAssertFalse(response?.contains("nextCursor") == true, "there is no next page to point at")
    }

    // MARK: - Errors

    func testAnUnknownMethodIsMinus32601() {
        XCTAssertEqual(
            handle(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#),
            #"{"error":{"code":-32601,"message":"Method not found: resources/list"},"id":3,"jsonrpc":"2.0"}"#
        )
    }

    func testBrokenJSONIsAParseErrorWithANullId() {
        XCTAssertEqual(
            handle("{ not json at all"),
            #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#
        )
    }

    func testAJSONValueThatIsNotAnObjectIsAnInvalidRequest() {
        XCTAssertEqual(
            handle("[1,2,3]"),
            #"{"error":{"code":-32600,"message":"Invalid Request: expected a JSON object"},"id":null,"jsonrpc":"2.0"}"#
        )
    }

    func testARequestWithNoMethodIsAnInvalidRequest() {
        XCTAssertEqual(
            handle(#"{"jsonrpc":"2.0","id":7}"#),
            #"{"error":{"code":-32600,"message":"Invalid Request: no method"},"id":7,"jsonrpc":"2.0"}"#
        )
    }

    func testBlankLinesAreSkipped() {
        XCTAssertNil(handle(""))
        XCTAssertNil(handle("   \t "))
    }

    /// JSON-RPC ids are numbers *or* strings, and a client that sent a string and got a
    /// number back would fail to match the response to its request.
    func testAStringIdComesBackAsAString() {
        XCTAssertEqual(
            handle(#"{"jsonrpc":"2.0","id":"req-1","method":"ping"}"#),
            #"{"id":"req-1","jsonrpc":"2.0","result":{}}"#
        )
    }

    // MARK: - tools/call

    private func sample(updatedAt: Date? = nil) -> StatusSnapshot {
        StatusSnapshot(
            version: 1,
            updatedAt: updatedAt ?? now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x",
                    windows: [
                        StatusSnapshot.Window(
                            id: "five_hour", label: "Session", percent: 42,
                            resetsAt: now.addingTimeInterval(70 * 60), kind: "session"
                        ),
                    ],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(
                needsYou: 1, working: 2,
                sessions: [StatusSnapshot.Session(id: "claude:a", project: "Usage tracker", state: "needsYou", activity: "Remove build artifacts")]
            )
        )
    }

    private func callResult(_ tool: String, snapshot: StatusSnapshot?) throws -> [String: Any] {
        let line = try XCTUnwrap(handle(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#, snapshot: snapshot))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    func testGetUsageReturnsAParagraphTheDataAndStructuredContent() throws {
        let result = try callResult("get_usage", snapshot: sample())

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2, "the paragraph, then the same data serialised")
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertTrue((content[0]["text"] as? String)?.contains("Claude (Max 5x): session 42%") == true, String(describing: content[0]))
        XCTAssertTrue((content[1]["text"] as? String)?.contains("\"todayCost\":4.2") == true, String(describing: content[1]))
        XCTAssertEqual(result["isError"] as? Bool, false)

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertNotNil(structured["services"])
        XCTAssertNil(structured["agents"], "get_usage is about limits; get_agents is the other tool")
    }

    func testGetAgentsReturnsTheCountsAndTheSessions() throws {
        let result = try callResult("get_agents", snapshot: sample())

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content[0]["text"] as? String)?.hasPrefix("1 session needs a decision from you and 2 are working.") == true, String(describing: content[0]))

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let agents = try XCTUnwrap(structured["agents"] as? [String: Any])
        XCTAssertEqual(agents["needsYou"] as? Int, 1)
        XCTAssertEqual((agents["sessions"] as? [[String: Any]])?.first?["project"] as? String, "Usage tracker")
        XCTAssertNil(structured["services"])
        XCTAssertNotNil(structured["updatedAt"], "a count with no timestamp is a guess")
    }

    func testWithOmeletteClosedBothToolsSaySoAsAResultNotAnError() throws {
        for tool in ["get_usage", "get_agents"] {
            let result = try callResult(tool, snapshot: nil)
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            XCTAssertEqual(content.first?["text"] as? String, CLIText.notRunning + ".", tool)
        }
    }

    func testAnUnknownToolIsMinus32602() {
        XCTAssertEqual(
            handle(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"delete_everything"}}"#, snapshot: sample()),
            #"{"error":{"code":-32602,"message":"Unknown tool: delete_everything"},"id":9,"jsonrpc":"2.0"}"#
        )
    }

    func testToolsCallWithNoNameIsMinus32602() {
        XCTAssertEqual(
            handle(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{}}"#, snapshot: sample()),
            #"{"error":{"code":-32602,"message":"tools/call needs a tool name"},"id":9,"jsonrpc":"2.0"}"#
        )
    }
}
