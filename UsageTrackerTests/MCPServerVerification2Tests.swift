import XCTest
@testable import Omelette

/// Second-round independent verification of `MCPServer` / `MCPSummary`, for the
/// `fix/3.0-followups` package contract item 6. Checks the claims the rewritten
/// `instructions` and tool descriptions actually make, against the code, not against
/// `MCPServerTests.swift` / `MCPServerVerificationTests.swift` (round 1, pre-dates this
/// package) or `MCPSessionsTests.swift` / `MCPSessionLimitVerificationTests.swift`:
///
/// (a) every non-error result carries `updatedAt`;
/// (b) with no readable snapshot every tool — not just `get_usage`/`get_agents` — returns
///     an error *result*, never a JSON-RPC protocol error;
/// (c) a snapshot older than ten minutes says Omelette may not be running;
/// (d) `get_sessions`' `limit` maximum is 15, default 10, newest first;
/// (f) cost is called an API-list-price equivalent only where `apiEquivalent` is true.
final class MCPServerVerification2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func handle(_ line: String, snapshot: StatusSnapshot?) -> String? {
        MCPServer.handle(line, snapshot: snapshot, now: now)
    }

    private func window(percent: Double = 10) -> StatusSnapshot.Window {
        StatusSnapshot.Window(id: "five_hour", label: "Session", percent: percent, resetsAt: nil, kind: "session")
    }

    private func service(
        id: String = "claude", apiEquivalent: Bool? = nil, sessions: [StatusSnapshot.SessionEntry]? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: id.capitalized, state: "ok", retained: false, retainedAt: nil, plan: "Max 5x",
            windows: [window()], todayCost: 4.2, weekCost: 31.7, todayTokens: 1000, apiEquivalent: apiEquivalent,
            sessions: sessions
        )
    }

    private func snapshot(updatedAt: Date, sessions: [StatusSnapshot.SessionEntry]? = nil) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: updatedAt,
            services: [service(sessions: sessions)],
            agents: StatusSnapshot.Agents(needsYou: 0, working: 0, sessions: [])
        )
    }

    private func callResult(_ tool: String, arguments: String = "{}", snapshot: StatusSnapshot?) throws -> [String: Any] {
        let line = try XCTUnwrap(handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#,
            snapshot: snapshot
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    // MARK: - (a) every non-error result carries updatedAt

    func testEveryToolsStructuredContentCarriesUpdatedAtWithAReadableSnapshot() throws {
        let file = snapshot(updatedAt: now, sessions: [
            StatusSnapshot.SessionEntry(id: "s1", title: "One", project: "Usage tracker", lastAt: now, turns: 1, tokens: 100, cost: 1, agents: 0, origin: nil),
        ])
        for tool in ["get_usage", "get_agents", "get_sessions"] {
            let result = try callResult(tool, snapshot: file)
            XCTAssertEqual(result["isError"] as? Bool, false, tool)
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any], tool)
            XCTAssertNotNil(structured["updatedAt"], "\(tool) must carry updatedAt in its structured data")
            XCTAssertFalse(structured["updatedAt"] is NSNull, tool)
        }
    }

    // MARK: - (b) no snapshot: every tool, not just two of three

    func testAllThreeToolsReturnAnErrorResultRatherThanAProtocolErrorWhenThereIsNoSnapshot() throws {
        for tool in ["get_usage", "get_agents", "get_sessions"] {
            let result = try callResult(tool, snapshot: nil)
            XCTAssertEqual(result["isError"] as? Bool, true, tool)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], tool)
            XCTAssertEqual(content.first?["text"] as? String, CLIText.notRunning + ".", tool)
            // A result, not a JSON-RPC error object: no top-level "error" key, and the
            // envelope still carries "result".
            let line = try XCTUnwrap(handle(
                #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#,
                snapshot: nil
            ))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(object["result"], tool)
            XCTAssertNil(object["error"], "\(tool): a closed Omelette is an answer, not a JSON-RPC error")
        }
    }

    // MARK: - (c) freshness boundary: StatusSnapshot.freshness is 600s

    func testJustUnderTenMinutesOldStillReadsAsCurrent() throws {
        let file = snapshot(updatedAt: now.addingTimeInterval(-599))
        for (tool, text) in try textsFor(file) {
            XCTAssertFalse(text.contains("may not be running"), "\(tool): \(text)")
        }
    }

    func testExactlyTenMinutesOldAlreadySaysItMayNotBeRunning() throws {
        let file = snapshot(updatedAt: now.addingTimeInterval(-600))
        XCTAssertFalse(file.isFresh(now: now), "600s must already be past StatusSnapshot.freshness")
        for (tool, text) in try textsFor(file) {
            XCTAssertTrue(text.contains("Omelette may not be running"), "\(tool): \(text)")
        }
    }

    private func textsFor(_ file: StatusSnapshot) throws -> [(String, String)] {
        var pairs: [(String, String)] = []
        for tool in ["get_usage", "get_agents", "get_sessions"] {
            let result = try callResult(tool, snapshot: file)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]], tool)
            let text = try XCTUnwrap(content.first?["text"] as? String, tool)
            pairs.append((tool, text))
        }
        return pairs
    }

    // MARK: - (d) get_sessions: limit 15 maximum, 10 default, newest first

    private func sessionEntries(_ count: Int) -> [StatusSnapshot.SessionEntry] {
        (0..<count).map { index in
            StatusSnapshot.SessionEntry(
                id: "s\(index)", title: "Chat \(index)", project: "Usage tracker",
                // Descending age by index, so index 0 is the newest.
                lastAt: now.addingTimeInterval(-Double(index) * 3600),
                turns: 1, tokens: 100, cost: nil, agents: 0, origin: nil
            )
        }
    }

    func testWithNoLimitArgumentTheStructuredListIsCutAtTheDefaultOfTen() throws {
        let file = snapshot(updatedAt: now, sessions: sessionEntries(20))
        let result = try callResult("get_sessions", arguments: "{}", snapshot: file)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 10, "MCPSummary.defaultSessionLimit is 10")
        XCTAssertEqual(sessions.map { $0["id"] as? String }, (0..<10).map { "s\($0)" }, "newest first")
    }

    func testALimitAboveFifteenOnTheWireStillClampsToFifteen() throws {
        let file = snapshot(updatedAt: now, sessions: sessionEntries(20))
        let result = try callResult("get_sessions", arguments: #"{"limit":50}"#, snapshot: file)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 15, "the file never carries more than fifteen chats per the schema's own maximum")
        XCTAssertEqual(sessions.map { $0["id"] as? String }, (0..<15).map { "s\($0)" })
    }

    func testTheSchemaItselfDeclaresTheSameFifteenAndDefaultTen() {
        let sessionsTool = MCPServer.toolDefinitions.first { $0["name"] as? String == "get_sessions" }
        let schema = sessionsTool?["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let limit = properties?["limit"] as? [String: Any]
        XCTAssertEqual(limit?["minimum"] as? Int, 1)
        XCTAssertEqual(limit?["maximum"] as? Int, 15)
        XCTAssertEqual(MCPSummary.defaultSessionLimit, 10)
    }

    // MARK: - (f) cost is API-list-price-equivalent only where apiEquivalent is true

    func testAnApiEquivalentServicesSentenceSaysSo() {
        let sentence = MCPSummary.serviceSentence(service(id: "claude", apiEquivalent: true), now: now)
        XCTAssertTrue(sentence.contains("(API-equivalent, not a subscription bill)"), sentence)
    }

    func testAPayAsYouGoServicesSentenceNeverSaysApiEquivalent() {
        let sentence = MCPSummary.serviceSentence(
            StatusSnapshot.Service(
                id: "codex", name: "Codex", state: "ok", retained: false, retainedAt: nil, plan: "Pay as you go",
                windows: [window()], todayCost: 4.2, weekCost: 31.7, todayTokens: 1000, apiEquivalent: false
            ),
            now: now
        )
        XCTAssertTrue(sentence.contains("$4.20 today"), sentence)
        XCTAssertFalse(sentence.contains("API-equivalent"), sentence)
    }

    /// Absent, not merely false: a provider whose file carries no `apiEquivalent` key
    /// at all (Grok, Antigravity) must not be misquoted as a subscription bill either.
    func testAServiceWithNoApiEquivalentKeyAtAllAlsoSaysNothingAboutIt() {
        let sentence = MCPSummary.serviceSentence(
            StatusSnapshot.Service(
                id: "grok", name: "Grok", state: "ok", retained: false, retainedAt: nil, plan: nil,
                windows: [window()], todayCost: 2.0, weekCost: nil, todayTokens: nil, apiEquivalent: nil
            ),
            now: now
        )
        XCTAssertTrue(sentence.contains("$2.00 today"), sentence)
        XCTAssertFalse(sentence.contains("API-equivalent"), sentence)
    }
}
