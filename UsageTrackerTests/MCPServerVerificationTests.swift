import XCTest
@testable import Omelette

/// Independent verification of `MCPServer`, derived from JSON-RPC 2.0 and MCP's own
/// spec plus the plan's Tasks 10-11, not from `MCPServerTests`. Focus: a batch array of
/// real request objects, an explicit JSON `null` id (a notification is defined by the
/// *absence* of the `id` key, not by it being falsy), a numeric id of 0, and that
/// `structuredContent`'s numbers agree with the paragraph `get_usage` prints.
final class MCPServerVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func handle(_ line: String, snapshot: StatusSnapshot? = nil) -> String? {
        MCPServer.handle(line, snapshot: snapshot, now: now)
    }

    private func sample() -> StatusSnapshot {
        StatusSnapshot(
            version: 1, updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x",
                    windows: [StatusSnapshot.Window(
                        id: "five_hour", label: "Session", percent: 42,
                        resetsAt: now.addingTimeInterval(70 * 60), kind: "session"
                    )],
                    todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567, apiEquivalent: true
                ),
            ],
            agents: .none
        )
    }

    /// A real JSON-RPC 2.0 batch: an array of well-formed request objects, not an
    /// array of scalars. Nothing in `handle` fans an array out into several responses
    /// — it only ever accepts one object per line — so this is one Invalid Request, and
    /// specifically not silently dropped (nil) the way a notification would be.
    func testABatchOfWellFormedRequestObjectsIsOneInvalidRequestNotDropped() {
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#
        let response = handle(batch)

        XCTAssertNotNil(response, "a batch line must get an answer, not silent drop")
        XCTAssertEqual(response, #"{"error":{"code":-32600,"message":"Invalid Request: expected a JSON object"},"id":null,"jsonrpc":"2.0"}"#)
    }

    /// JSON-RPC defines a notification as a request with no `id` member at all — not
    /// one whose id happens to be `null` or `0`. `object["id"]` is a dictionary lookup:
    /// an explicit `"id": null` decodes to `NSNull()`, which is present (Optional.some),
    /// so this must still be answered, with the id echoed back as JSON null.
    func testAnExplicitNullIdIsAnsweredNotTreatedAsANotification() {
        let response = handle(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
        XCTAssertEqual(response, #"{"id":null,"jsonrpc":"2.0","result":{}}"#)
    }

    /// `id: 0` is falsy in many languages but is a perfectly ordinary JSON-RPC id.
    func testIdZeroIsAnsweredAndEchoedAsZeroNotDroppedAsFalsy() {
        let response = handle(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#)
        XCTAssertEqual(response, #"{"id":0,"jsonrpc":"2.0","result":{}}"#)
    }

    /// The `structuredContent` object handed back from `get_usage` must carry the same
    /// `todayCost` the paragraph in `content[0].text` describes — an agent that only
    /// reads the structured half must see the same dollar figure a human reading the
    /// sentence would.
    func testStructuredContentAgreesWithPagraphNumbersForGetUsage() throws {
        let line = try XCTUnwrap(handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_usage"}}"#, snapshot: sample()
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let paragraph = try XCTUnwrap(content.first?["text"] as? String)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        let claude = try XCTUnwrap(services.first)

        XCTAssertTrue(paragraph.contains("$4.20 today"), paragraph)
        XCTAssertEqual(claude["todayCost"] as? Double, 4.2)
        XCTAssertEqual(claude["weekCost"] as? Double, 31.7)
        XCTAssertTrue(paragraph.contains("session 42%"), paragraph)
        XCTAssertEqual((claude["windows"] as? [[String: Any]])?.first?["percent"] as? Double, 42)
    }

    /// Same cross-check for `get_agents`: the paragraph's counts and the structured
    /// `needsYou`/`working` must be the same numbers.
    func testStructuredContentAgreesWithParagraphCountsForGetAgents() throws {
        var withAgents = sample()
        withAgents.agents = StatusSnapshot.Agents(
            needsYou: 2, working: 1,
            sessions: [StatusSnapshot.Session(id: "a", project: "P", state: "needsYou", activity: nil)]
        )
        let line = try XCTUnwrap(handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_agents"}}"#, snapshot: withAgents
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let paragraph = try XCTUnwrap(content.first?["text"] as? String)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let agents = try XCTUnwrap(structured["agents"] as? [String: Any])

        XCTAssertTrue(paragraph.contains("2 sessions need a decision from you"), paragraph)
        XCTAssertEqual(agents["needsYou"] as? Int, 2)
        XCTAssertEqual(agents["working"] as? Int, 1)
    }
}
