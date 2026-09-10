import XCTest
@testable import Omelette

/// Independent verification of `get_sessions` (`MCPSummary`, `MCPServer`) against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § 5: "new tool
/// `get_sessions` with optional `provider` (`claude` / `codex`) and `limit`". Written
/// from the spec and the diff, not from `MCPSessionsTests` — this file pins what the
/// spec leaves ambiguous (an unrecognised `provider` string is a client bypassing the
/// schema's `enum`, which `MCPSummary.sessionRows`/`sessionsData` do not themselves
/// enforce), the fractional and non-numeric shapes `sessionLimit` was not shown with,
/// and the schema's exact bounds read back structurally rather than as one long string.
final class MCPSessionsVerificationTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale
    private var now: Date { SessionFixture.now }

    private func entry(id: String, agents: Int = 0, origin: String? = nil) -> StatusSnapshot.SessionEntry {
        StatusSnapshot.SessionEntry(
            id: id, title: "Chat \(id)", project: "Usage tracker",
            lastAt: now.addingTimeInterval(-3600), turns: 10, tokens: 1_000,
            cost: 1.5, agents: agents, origin: origin
        )
    }

    private func service(id: String, sessions: [StatusSnapshot.SessionEntry]) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: id == "claude" ? "Claude" : "Codex", state: "ok", retained: false, retainedAt: nil,
            plan: nil, windows: [], todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil,
            sessions: sessions
        )
    }

    private func snapshot(_ services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none)
    }

    // MARK: - A provider name the schema does not know

    /// The JSON schema's `enum` is documentation to a model, not enforcement by the
    /// server (`MCPServer.sessionsInputSchema`'s own doc comment says as much). A client
    /// that sends a `provider` outside {claude, codex} must get a quiet empty answer,
    /// not a crash and not a protocol error.
    func testAnUnrecognisedProviderNameYieldsAnEmptyAnswerNeverAnErrorOrCrash() throws {
        let snap = snapshot([service(id: "claude", sessions: [entry(id: "s1")])])

        let rows = MCPSummary.sessionRows(snap, provider: "banana", limit: 10)
        XCTAssertTrue(rows.isEmpty)

        let text = MCPSummary.sessions(snapshot: snap, provider: "banana", limit: 10, now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(text.hasPrefix("No banana chats in the last 7 days."), text)

        let line = try XCTUnwrap(MCPServer.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_sessions","arguments":{"provider":"banana"}}}"#,
            snapshot: snap, now: now
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "an empty list is a valid answer, not a tool failure")
    }

    // MARK: - sessionLimit on inputs the existing suite does not try

    func testSessionLimitTruncatesFractionalDoublesTowardZero() {
        XCTAssertEqual(MCPSummary.sessionLimit(3.9), 3)
        XCTAssertEqual(MCPSummary.sessionLimit(0.9), 1, "truncates to 0, then clamped up to the floor of 1")
        XCTAssertEqual(MCPSummary.sessionLimit(20.9), 15, "truncates to 20, then clamped down to the ceiling")
    }

    func testSessionLimitFallsBackToTheDefaultForATypeItCannotRead() {
        XCTAssertEqual(MCPSummary.sessionLimit(true), 10, "a bool is neither a number nor numeric text")
        XCTAssertEqual(MCPSummary.sessionLimit([1, 2, 3]), 10)
        XCTAssertEqual(MCPSummary.sessionLimit(NSNull()), 10)
    }

    // MARK: - The exec chip's exact position in the line

    func testTheExecChipIsTheVeryLastThingOnTheLineAfterSubAgents() {
        let service = StatusSnapshot.Service(
            id: "codex", name: "Codex", state: "ok", retained: false, retainedAt: nil, plan: nil,
            windows: [], todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil, sessions: nil
        )
        let session = entry(id: "t1", agents: 2, origin: "codex_exec")

        let line = MCPSummary.sessionLine(service, session, now: now, calendar: calendar, locale: locale)

        XCTAssertTrue(line.hasSuffix("2 sub-agents · exec"), line)
    }

    // MARK: - The schema, read structurally rather than as one exact string

    func testTheSessionsToolSchemaBoundsAreExactlyOneToFifteenAndTwoProviders() throws {
        let def = try XCTUnwrap(MCPServer.toolDefinitions.first { ($0["name"] as? String) == "get_sessions" })
        let schema = try XCTUnwrap(def["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        let provider = try XCTUnwrap(properties["provider"] as? [String: Any])
        XCTAssertEqual(provider["enum"] as? [String], ["claude", "codex"])

        let limit = try XCTUnwrap(properties["limit"] as? [String: Any])
        XCTAssertEqual(limit["minimum"] as? Int, 1)
        XCTAssertEqual(limit["maximum"] as? Int, 15)
    }
}
