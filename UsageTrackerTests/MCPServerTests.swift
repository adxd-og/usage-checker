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

        XCTAssertEqual(response, #"{"id":4,"jsonrpc":"2.0","result":{"tools":[{"description":"Every provider Omelette tracks: each rate-limit window's percent and when it resets, today's and this week's cost, and whether those dollars are an API-equivalent figure rather than a subscription bill. Call this before starting long or expensive work.","inputSchema":{"additionalProperties":false,"properties":{},"type":"object"},"name":"get_usage","title":"AI usage right now"},{"description":"The Claude Code and Codex sessions Omelette can see: how many need a decision from the user, how many are working, and what each one is doing.","inputSchema":{"additionalProperties":false,"properties":{},"type":"object"},"name":"get_agents","title":"Agent sessions right now"}]}}"#)
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
}
