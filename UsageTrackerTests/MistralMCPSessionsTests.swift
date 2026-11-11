import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Sessions: Mistral's chats reach MCP
/// `get_sessions` through `status.json`, and the tool says so: its description names them and
/// its `provider` argument takes `mistral` (plan R15).
final class MistralMCPSessionsTests: XCTestCase {
    /// 2026-11-06 18:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)

    private var snapshot: StatusSnapshot {
        let vibeChat = StatusSnapshot.SessionEntry(
            id: "vibe-chat", title: "Fixture title", project: "Vibe Fixtures / probe",
            lastAt: now.addingTimeInterval(-3_600), turns: 6, tokens: 66_132, cost: 0.02, agents: 0
        )
        let codexChat = StatusSnapshot.SessionEntry(
            id: "codex-chat", title: "Other", project: "elsewhere", lastAt: now, turns: 1, tokens: 10, cost: 0.01, agents: 0
        )
        return StatusSnapshot(version: 2, updatedAt: now, services: [
            StatusSnapshot.Service(id: "codex", name: "Codex", state: "ok", retained: false, windows: [], apiEquivalent: true, sessions: [codexChat]),
            StatusSnapshot.Service(id: "mistral", name: "Mistral", state: "ok", retained: false, windows: [], apiEquivalent: true, sessions: [vibeChat]),
        ], agents: .none)
    }

    func testGetSessionsCanAskForMistralsChatsAlone() throws {
        XCTAssertEqual(MCPSummary.sessionRows(snapshot, provider: "mistral", limit: 10).map { $0.session.id }, ["vibe-chat"])
        XCTAssertEqual(MCPSummary.sessionRows(snapshot, provider: nil, limit: 10).map { $0.session.id }, ["codex-chat", "vibe-chat"])
        let tool = try XCTUnwrap(MCPServer.toolDefinitions.first { ($0["name"] as? String) == "get_sessions" })
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.hasPrefix("The recent Claude Code, Codex and Mistral vibe chats Brioche can see"), description)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let provider = try XCTUnwrap(properties["provider"] as? [String: Any])
        XCTAssertEqual(provider["enum"] as? [String], ["claude", "codex", "mistral"])
    }
}
