import XCTest
@testable import Omelette

/// The `get_sessions` tool: the paragraph a model reads, the argument clamp, and the
/// structured half. Exact strings — this is what an agent will quote back to the user
/// when they ask what a chat cost.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 5, § 6.
final class MCPSessionsTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func entry(
        id: String, title: String, project: String = "Usage tracker",
        hoursAgo: Double = 3, turns: Int = 356, tokens: Int = 41_200_000,
        cost: Double? = 58.10, agents: Int = 3, origin: String? = nil
    ) -> StatusSnapshot.SessionEntry {
        StatusSnapshot.SessionEntry(
            id: id, title: title, project: project,
            lastAt: now.addingTimeInterval(-hoursAgo * 3600),
            turns: turns, tokens: tokens, cost: cost, agents: agents, origin: origin
        )
    }

    private func service(
        id: String = "claude", name: String = "Claude", sessions: [StatusSnapshot.SessionEntry]
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: name, state: "ok", retained: false, retainedAt: nil, plan: "Max 5x",
            windows: [], todayCost: nil, weekCost: nil, todayTokens: nil, apiEquivalent: nil,
            sessions: sessions
        )
    }

    private func snapshot(_ services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none
        )
    }

    private func text(_ snapshot: StatusSnapshot, provider: String? = nil, limit: Int = 10) -> String {
        MCPSummary.sessions(
            snapshot: snapshot, provider: provider, limit: limit,
            now: now, calendar: calendar, locale: locale
        )
    }

    // MARK: - The paragraph

    func testAChatIsOneLineWithEveryFigureAnAgentWouldQuote() {
        let out = text(snapshot([service(sessions: [entry(id: "s1", title: "Интеграция Blume")])]))

        XCTAssertEqual(
            out,
            """
            Claude · Интеграция Blume · Usage tracker · today 8:20 · 356 turns · 41.2M tokens · $58.10 · 3 sub-agents
            Numbers as of 11:20.
            """
        )
    }

    func testAChatWithNoSubAgentsSaysNothingAboutThem() {
        let out = text(snapshot([service(sessions: [entry(id: "s1", title: "Quick fix", agents: 0)])]))
        XCTAssertTrue(out.hasPrefix("Claude · Quick fix · Usage tracker · today 8:20 · 356 turns · 41.2M tokens · $58.10\n"), out)
    }

    func testACodexChatAnAgentDroveIsMarkedExec() {
        let out = text(snapshot([service(
            id: "codex", name: "Codex",
            sessions: [entry(id: "t1", title: "Installer review", agents: 0, origin: "codex_exec")]
        )]))
        XCTAssertTrue(out.contains("· $58.10 · exec"), out)
    }

    func testChatsFromEveryProviderAreMergedNewestFirst() {
        let out = text(snapshot([
            service(sessions: [entry(id: "s1", title: "Older", hoursAgo: 30)]),
            service(id: "codex", name: "Codex", sessions: [entry(id: "t1", title: "Newer", hoursAgo: 1)]),
        ]))
        let lines = out.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines[0].hasPrefix("Codex · Newer"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("Claude · Older"), lines[1])
    }

    func testNamingAProviderAsksAboutThatProviderOnly() {
        let out = text(
            snapshot([
                service(sessions: [entry(id: "s1", title: "Claude one")]),
                service(id: "codex", name: "Codex", sessions: [entry(id: "t1", title: "Codex one")]),
            ]),
            provider: "codex"
        )

        XCTAssertTrue(out.contains("Codex one"), out)
        XCTAssertFalse(out.contains("Claude one"), out)
    }

    func testTheLimitCutsTheListAndTheStampAlwaysSurvives() {
        let entries = (1...12).map { entry(id: "s\($0)", title: "Chat \($0)", hoursAgo: Double($0)) }
        let out = text(snapshot([service(sessions: entries)]), limit: 3)
        let lines = out.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 4, "three chats and the stamp")
        XCTAssertTrue(lines[0].contains("Chat 1"), lines[0])
        XCTAssertEqual(lines[3], "Numbers as of 11:20.")
    }

    func testAQuietWeekSaysSoAndSaysWhen() {
        XCTAssertEqual(
            text(snapshot([service(sessions: [])])),
            "No chats in the last 7 days. Numbers as of 11:20."
        )
        XCTAssertEqual(
            text(snapshot([service(sessions: [])]), provider: "codex"),
            "No codex chats in the last 7 days. Numbers as of 11:20."
        )
    }

    func testStaleNumbersSayTheyAreStaleHereToo() {
        let stale = StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now.addingTimeInterval(-3600),
            services: [service(sessions: [entry(id: "s1", title: "Anything")])], agents: .none
        )
        XCTAssertTrue(
            text(stale).hasSuffix("Omelette may not be running, so treat them as the last thing it saw."),
            text(stale)
        )
    }

    // MARK: - The argument

    func testTheLimitIsClampedRatherThanTrusted() {
        XCTAssertEqual(MCPSummary.sessionLimit(nil), 10, "the default the tool advertises")
        XCTAssertEqual(MCPSummary.sessionLimit(3), 3)
        XCTAssertEqual(MCPSummary.sessionLimit(99), 15, "the file never holds more than fifteen")
        XCTAssertEqual(MCPSummary.sessionLimit(0), 1)
        XCTAssertEqual(MCPSummary.sessionLimit(-4), 1)
        XCTAssertEqual(MCPSummary.sessionLimit("7"), 7, "a model that sends a string still gets an answer")
        XCTAssertEqual(MCPSummary.sessionLimit(7.0), 7)
        XCTAssertEqual(MCPSummary.sessionLimit("lots"), 10)
        XCTAssertEqual(MCPSummary.defaultSessionLimit, 10)
        XCTAssertEqual(MCPSummary.maxSessionLimit, 15)
    }

    // MARK: - The tool call

    private func callResult(_ arguments: String, snapshot: StatusSnapshot?) throws -> [String: Any] {
        let line = try XCTUnwrap(MCPServer.handle(
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_sessions","arguments":\#(arguments)}}"#,
            snapshot: snapshot, now: now
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    func testGetSessionsReturnsAParagraphAndTheChatsAsData() throws {
        let result = try callResult("{}", snapshot: snapshot([service(sessions: [entry(id: "s1", title: "Интеграция Blume")])]))

        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content[0]["text"] as? String)?.hasPrefix("Claude · Интеграция Blume") == true, String(describing: content[0]))
        XCTAssertEqual(result["isError"] as? Bool, false)

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["title"] as? String, "Интеграция Blume")
        XCTAssertEqual(sessions.first?["turns"] as? Int, 356)
        XCTAssertNotNil(structured["updatedAt"], "a list with no timestamp is a guess")
        XCTAssertNil(services.first?["windows"], "windows and dollars belong to get_usage")
    }

    func testTheStructuredHalfIsCutByTheSameProviderAndLimit() throws {
        let result = try callResult(
            #"{"provider":"codex","limit":1}"#,
            snapshot: snapshot([
                service(sessions: [entry(id: "s1", title: "Claude one")]),
                service(id: "codex", name: "Codex", sessions: [
                    entry(id: "t1", title: "Codex newer", hoursAgo: 1),
                    entry(id: "t2", title: "Codex older", hoursAgo: 9),
                ]),
            ])
        )

        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        XCTAssertEqual(services.count, 1, "a provider with nothing left to show is dropped entirely")
        XCTAssertEqual(services.first?["id"] as? String, "codex")
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["id"] as? String }, ["t1"])
    }

    func testWithOmeletteClosedTheToolSaysSoAsAResultNotAnError() throws {
        let result = try callResult("{}", snapshot: nil)

        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, CLIText.notRunning + ".")
    }

    func testTheInstructionsMentionTheNewTool() {
        XCTAssertTrue(
            MCPServer.instructions.contains("get_sessions lists the recent chats with their token and cost totals."),
            MCPServer.instructions
        )
    }
}
