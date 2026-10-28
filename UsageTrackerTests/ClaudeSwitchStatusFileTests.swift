import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, CLI and MCP. With
/// Claude switched off, and with every provider off, `status.json` keeps schema 2 and its
/// state strings; `omelette status` and the status line print no Claude window and no
/// Claude dollars, the status line keeping the session's own prefix; `get_usage` answers
/// an empty list, not an error (an empty snapshot is not a missing one); `get_sessions`
/// lists no Claude chat; `get_agents` still reports the hook sessions. The files are built
/// as the app builds them, `StatusFileWriter.build` over the services a poll returned,
/// with the gather's caches still holding Claude's dollars and chats from before the
/// switch moved.
final class ClaudeSwitchStatusFileTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale
    /// Sunday 2026-09-06 11:20 UTC.
    private let now = SessionFixture.now
    private let input = StatusLineInput(model: "Fable", contextUsedPercent: 42.4)

    private func codex() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(
                id: "codex_session", label: "Session", percent: 30,
                resetsAt: now.addingTimeInterval(2 * 3600), kind: .session
            )],
            at: now
        )
    }

    private func chat(_ id: String, provider: String) -> SessionSummary {
        SessionFixture.session(
            id: id, providerID: provider, title: "Release review",
            lastAt: SessionFixture.at(hoursBefore: 2),
            tokens: SessionFixture.tokens(input: 10_000, output: 1_000, cost: SessionFixture.cost(input: 1.5))
        )
    }

    private let waiting = StatusFileWriter.AgentSummary(
        needsYou: 1, working: 0,
        sessions: [StatusSnapshot.Session(
            id: "claude:a", project: "Usage tracker", state: "needsYou", activity: "Remove build artifacts"
        )]
    )

    /// Claude off: the poll returned Codex alone.
    private func claudeOff(agents: StatusFileWriter.AgentSummary = .none) -> StatusSnapshot {
        StatusFileWriter.build(
            services: [codex()],
            costs: [
                "claude": .init(todayCost: 12.5, weekCost: 80, todayTokens: 900_000),
                "codex": .init(todayCost: 2.25, weekCost: 9, todayTokens: 40_000),
            ],
            sessions: ["claude": [chat("c1", provider: "claude")], "codex": [chat("x1", provider: "codex")]],
            agents: agents, now: now, calendar: calendar, locale: locale
        )
    }

    /// Everything off: the poll returned nothing.
    private func everythingOff(agents: StatusFileWriter.AgentSummary = .none) -> StatusSnapshot {
        StatusFileWriter.build(services: [], costs: [:], agents: agents, now: now, calendar: calendar, locale: locale)
    }

    private func call(_ tool: String, arguments: String = "{}", snapshot: StatusSnapshot) throws -> [String: Any] {
        let line = try XCTUnwrap(MCPServer.handle(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#,
            snapshot: snapshot, now: now
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func serviceIDs(_ result: [String: Any]) throws -> [String] {
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let services = try XCTUnwrap(structured["services"] as? [[String: Any]])
        return services.compactMap { $0["id"] as? String }
    }

    // MARK: - status.json

    func testTheFileKeepsSchemaTwoAndItsStateWords() throws {
        for snapshot in [claudeOff(agents: waiting), everythingOff(agents: waiting)] {
            XCTAssertEqual(snapshot.version, 2)
            let back = try StatusFile.decoder.decode(StatusSnapshot.self, from: StatusFile.encoder.encode(snapshot))
            XCTAssertEqual(back, snapshot)
        }
        XCTAssertEqual(claudeOff().services.map(\.id), ["codex"])
        XCTAssertEqual(claudeOff().services.map(\.state), ["ok"])
        XCTAssertTrue(everythingOff().services.isEmpty)
    }

    func testClaudesKeptDollarsAndChatsDoNotReachTheFile() {
        let file = claudeOff()
        XCTAssertNil(file.service(id: "claude"))
        XCTAssertEqual(file.service(id: "codex")?.todayCost, 2.25)
        XCTAssertEqual(file.service(id: "codex")?.sessions?.map(\.id), ["x1"])
    }

    // MARK: - omelette status

    func testStatusWithClaudeOffPrintsNoClaudeLine() {
        let out = StatusText.render(snapshot: claudeOff(agents: waiting), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(out.hasPrefix("Codex  Session 30%"), out)
        XCTAssertTrue(out.contains("$2.25 today"), out)
        XCTAssertFalse(out.contains("Claude"), out)
        XCTAssertFalse(out.contains("$12.50"), out)
        XCTAssertTrue(out.hasSuffix("Agents: 1 needs you\n"), out)
    }

    func testStatusWithEverythingOffSaysNoProviderIsReporting() {
        XCTAssertEqual(
            StatusText.render(snapshot: everythingOff(), now: now, calendar: calendar, locale: locale),
            "No provider is reporting yet.\n"
        )
        XCTAssertEqual(
            StatusText.render(snapshot: everythingOff(agents: waiting), now: now, calendar: calendar, locale: locale),
            "Agents: 1 needs you\n",
            "the hook sessions are still there"
        )
    }

    // MARK: - omelette statusline

    func testTheStatusLineWithClaudeOffKeepsOnlyTheSessionPart() {
        XCTAssertEqual(
            StatusLineText.render(snapshot: claudeOff(), now: now, input: input, colour: false, calendar: calendar, locale: locale),
            "Fable [####------] 42%"
        )
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: claudeOff(agents: waiting), now: now, input: input, colour: false, calendar: calendar, locale: locale
            ),
            "Fable [####------] 42% · ⚑ 1",
            "a waiting agent is waiting whichever provider is on"
        )
    }

    func testTheStatusLineWithEverythingOffKeepsOnlyTheSessionPart() {
        XCTAssertEqual(
            StatusLineText.render(snapshot: everythingOff(), now: now, input: input, colour: false, calendar: calendar, locale: locale),
            "Fable [####------] 42%"
        )
    }

    // MARK: - MCP

    func testGetUsageWithClaudeOffListsTheOthersOnly() throws {
        let result = try call("get_usage", snapshot: claudeOff())
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(try serviceIDs(result), ["codex"])
        XCTAssertFalse(text(result).contains("Claude"), text(result))
    }

    func testGetUsageWithEverythingOffIsAnEmptyListNotAnError() throws {
        let result = try call("get_usage", snapshot: everythingOff())
        XCTAssertEqual(result["isError"] as? Bool, false, "an empty snapshot is not a missing one")
        XCTAssertEqual(try serviceIDs(result), [])
        XCTAssertTrue(text(result).hasPrefix(StatusText.emptyLine), text(result))
    }

    func testGetSessionsWithClaudeOffListsNoClaudeChat() throws {
        let all = try call("get_sessions", snapshot: claudeOff())
        XCTAssertEqual(try serviceIDs(all), ["codex"])

        let claudeOnly = try call("get_sessions", arguments: #"{"provider":"claude"}"#, snapshot: claudeOff())
        XCTAssertEqual(claudeOnly["isError"] as? Bool, false)
        XCTAssertEqual(try serviceIDs(claudeOnly), [])
        XCTAssertTrue(text(claudeOnly).hasPrefix("No claude chats in the last 7 days."), text(claudeOnly))
    }

    func testGetSessionsWithEverythingOffListsNothing() throws {
        let result = try call("get_sessions", snapshot: everythingOff())
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(try serviceIDs(result), [])
        XCTAssertTrue(text(result).hasPrefix("No chats in the last 7 days."), text(result))
    }

    func testGetAgentsIsUnchangedWithEverythingOff() throws {
        let result = try call("get_agents", snapshot: everythingOff(agents: waiting))
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let agents = try XCTUnwrap(structured["agents"] as? [String: Any])
        XCTAssertEqual(agents["needsYou"] as? Int, 1)
        XCTAssertEqual((agents["sessions"] as? [[String: Any]])?.first?["project"] as? String, "Usage tracker")
    }

    // MARK: - The gather

    func testWithEverythingOffTheGatherReadsNoLog() async {
        let gathered = await StatusCosts.gather(serviceIDs: [], services: [], now: now)
        XCTAssertTrue(gathered.costs.isEmpty)
        XCTAssertTrue(gathered.sessions.isEmpty)
        XCTAssertTrue(gathered.shares.isEmpty)
    }
}
