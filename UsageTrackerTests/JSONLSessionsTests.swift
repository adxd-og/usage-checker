import XCTest
@testable import Omelette

/// Sessions in History, the Claude half: spec
/// `docs/superpowers/specs/2026-09-10-sessions-history-design.md` § 2 and the
/// `sessions(from:to:)` contract of § 1.
///
/// The fixture lines are the shapes `~/.claude/projects` really holds on this Mac —
/// a main transcript, a sub-agent transcript under `<session>/subagents/`, the
/// `ai-title` record, the first human prompt behind a `<local-command-caveat>` meta
/// record — with ids, names and paths scrubbed. Dollar figures are asserted against
/// the static `ModelPricing` table, which is what the app uses offline.
final class JSONLSessionsTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let sessionID = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let otherSessionID = "90a2e89b-86f7-438b-bbb1-d0b5735809e3"
    private let alphaSlug = "-Users-tester-Projects-alpha"

    /// Every day boundary in these tests is UTC's, in the aggregator and in the
    /// fixtures alike, so a machine in any time zone bins the same turns into the
    /// same days.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: cacheFile(named: "control"))
    }

    /// Beside the log root, never inside it, and never in the real Application
    /// Support directory.
    private var cacheURL: URL { cacheFile(named: "cost-cache") }

    private func cacheFile(named name: String) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name).json")
    }

    // MARK: - Time

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `daysAgo` days before today at `hour` UTC. Relative, so a fixture never goes
    /// stale; pinned to UTC, so which day it falls in is not the machine's business.
    private func at(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: dayStart(daysAgo: daysAgo))!
    }

    private func dayStart(daysAgo: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    // MARK: - Fixture records

    /// A main-thread assistant record as Claude Code 2.1.263 writes it, content elided.
    private func mainTurn(
        id: String,
        at date: Date,
        model: String = "claude-sonnet-4-5",
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheCreate5m: Int = 0,
        thinking: Int = 0,
        effort: String = "high",
        session: String? = nil
    ) -> String {
        """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":false,\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreate5m),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "output_tokens_details":{"thinking_tokens":\(thinking)},\
        "cache_creation":{"ephemeral_5m_input_tokens":\(cacheCreate5m),"ephemeral_1h_input_tokens":0},\
        "service_tier":"standard"}},"apiBlockIndex":0,\
        "requestId":"req_011CenRuxq86v1VeS6TBkZqi","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"\(effort)",\
        "session_id":"\(session ?? sessionID)","userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)","version":"2.1.263",\
        "gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    /// A sub-agent record: `isSidechain`, `agentId`, `attributionAgent`, and the
    /// parent's `sessionId`.
    private func agentTurn(
        id: String,
        at date: Date,
        agentID: String,
        kind: String,
        model: String = "claude-opus-4-5",
        input: Int = 0,
        output: Int = 0,
        effort: String = "xhigh",
        session: String? = nil
    ) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CeqhfbvWNe5EU6Yax6z9r","attributionAgent":"\(kind)",\
        "attributionSkill":"superpowers:writing-plans","attributionPlugin":"superpowers",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"\(effort)",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session ?? sessionID)","version":"2.1.263","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":\(output),"service_tier":"standard"}}}
        """
    }

    private func titleLine(_ title: String, session: String? = nil) -> String {
        """
        {"type":"ai-title","aiTitle":"\(title)","sessionId":"\(session ?? sessionID)"}
        """
    }

    /// The user's own prompt: `origin.kind == "human"`.
    private func humanPromptLine(_ text: String, at date: Date, session: String? = nil) -> String {
        """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":"\(text)"},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: date))","permissionMode":"auto",\
        "origin":{"kind":"human"},"promptSource":"typed","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    /// The `<local-command-caveat>` record Claude Code writes as `type: user` with no
    /// `origin` at all — the record that would otherwise name every chat after the
    /// tool's own plumbing.
    private func metaUserLine(at date: Date, session: String? = nil) -> String {
        """
        {"parentUuid":"0d59b3e0-2fd3-485d-a2c2-c07a71157116","isSidechain":false,\
        "promptId":"02666905-bfe5-4d9b-befd-caca7d727c13","type":"user","isMeta":true,\
        "message":{"role":"user","content":"<local-command-caveat>Caveat: The messages \
        below were generated by the user while running local commands.</local-command-caveat>"},\
        "uuid":"e4dd1f49-636d-42ee-aff0-140fbec7d41b",\
        "timestamp":"\(Self.iso.string(from: date))","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)",\
        "version":"2.1.263","gitBranch":"main"}
        """
    }

    // MARK: - Fixture files

    private func writeMain(
        _ lines: [String], session: String? = nil, project: String? = nil
    ) throws {
        let dir = root.appendingPathComponent(project ?? alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session ?? sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    /// `<project>/<sessionId>/subagents/agent-<id>.jsonl`, exactly where Claude Code
    /// puts a sub-agent's transcript.
    private func writeSubagent(
        _ lines: [String], agentID: String, session: String? = nil, project: String? = nil
    ) throws {
        let dir = root
            .appendingPathComponent(project ?? alphaSlug, isDirectory: true)
            .appendingPathComponent(session ?? sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func aggregator(cache: URL? = nil, saveInterval: TimeInterval = 0) -> JSONLAggregator {
        JSONLAggregator(
            rootURL: root, cacheURL: cache, saveInterval: saveInterval, calendar: calendar
        )
    }

    // MARK: - The project a transcript belongs to

    func testTheProjectSlugIsTheLogRootsOwnChildDirectory() {
        let logRoot = URL(fileURLWithPath: "/tmp/projects", isDirectory: true)

        XCTAssertEqual(
            JSONLAggregator.projectSlug(
                for: URL(fileURLWithPath: "/tmp/projects/\(alphaSlug)/1111.jsonl"),
                root: logRoot
            ),
            alphaSlug,
            "a main transcript sits directly in its project directory"
        )
        XCTAssertEqual(
            JSONLAggregator.projectSlug(
                for: URL(fileURLWithPath: "/tmp/projects/\(alphaSlug)/1111/subagents/agent-a1.jsonl"),
                root: logRoot
            ),
            alphaSlug,
            "a sub-agent's parent directory is `subagents`, which is not a project"
        )
        XCTAssertEqual(
            JSONLAggregator.projectSlug(
                for: URL(fileURLWithPath: "/tmp/projects/\(alphaSlug)/1111/subagents/workflows/wf_1/journal.jsonl"),
                root: logRoot
            ),
            alphaSlug,
            "a workflow journal is deeper still"
        )
        XCTAssertEqual(
            JSONLAggregator.projectSlug(
                for: URL(fileURLWithPath: "/elsewhere/beta/2222.jsonl"),
                root: logRoot
            ),
            "beta",
            "a file outside the root keeps the old answer rather than inventing one"
        )
    }

    func testASubAgentsSpendLandsInTheProjectThatLaunchedIt() async throws {
        try writeMain([
            mainTurn(id: "msg_main", at: at(daysAgo: 1, hour: 12), input: 1_000_000),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_agent", at: at(daysAgo: 1, hour: 13),
                agentID: "a06ceeae2762ca204", kind: "planner", input: 1_000_000
            )],
            agentID: "a06ceeae2762ca204"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let usage = await aggregator.usage(from: at(daysAgo: 2, hour: 0), to: now)

        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(
            usage.projects.map(\.slug), [alphaSlug],
            "a `subagents` row is not a project the user has ever heard of"
        )
        XCTAssertEqual(usage.projects.first?.turns, 2)
    }

    // MARK: - What one record says

    func testAMainThreadRecordCarriesTheChatIdAndNoAgent() throws {
        var pool = StringPool()
        let line = mainTurn(
            id: "msg_011CenRuz2JaQEpHjsmYr9DF", at: at(daysAgo: 1, hour: 12),
            input: 42, output: 231, thinking: 34, effort: "high"
        )

        let record = try XCTUnwrap(JSONLAggregator.parseRecord(
            Data(line.utf8), projectSlug: alphaSlug,
            iso: Self.iso, isoNoFraction: Self.isoNoFraction, pool: &pool
        ))
        guard case .turn(let turn) = record else {
            return XCTFail("a `type: assistant` record is a turn, got \(record)")
        }

        XCTAssertEqual(turn.sessionID, sessionID)
        XCTAssertNil(turn.agentID, "the main thread is not an agent")
        XCTAssertNil(turn.agentKind)
        XCTAssertEqual(turn.effort, "high")
        XCTAssertEqual(turn.inputTokens, 42, "the counters this file already reported are untouched")
        XCTAssertEqual(turn.outputTokens, 231)
        XCTAssertEqual(turn.tokens.thinking, 34)
        XCTAssertEqual(turn.projectSlug, alphaSlug)
    }

    func testASubAgentRecordTakesItsIdentityFromTheRecordNotTheFileName() throws {
        var pool = StringPool()
        let line = agentTurn(
            id: "msg_011CeqhfcrpPectFAXxS1pNw", at: at(daysAgo: 1, hour: 13),
            agentID: "a06ceeae2762ca204", kind: "planner", input: 2, output: 1, effort: "xhigh"
        )

        let record = try XCTUnwrap(JSONLAggregator.parseRecord(
            Data(line.utf8), projectSlug: alphaSlug,
            iso: Self.iso, isoNoFraction: Self.isoNoFraction, pool: &pool
        ))
        guard case .turn(let turn) = record else {
            return XCTFail("a sidechain assistant record is a turn, got \(record)")
        }

        XCTAssertEqual(turn.agentID, "a06ceeae2762ca204", "`agentId`, never the file name")
        XCTAssertEqual(turn.agentKind, "planner", "`attributionAgent` is the agent's type")
        XCTAssertEqual(turn.effort, "xhigh")
        XCTAssertEqual(
            turn.sessionID, sessionID,
            "a sub-agent's transcript carries the parent chat's own session id"
        )
    }

    func testARecordWithNoSessionIdStillParsesAsATurn() throws {
        // Builds old enough to omit `sessionId` still spent money; the turn counts, it
        // simply belongs to no chat.
        var pool = StringPool()
        let line = """
        {"type":"assistant","timestamp":"\(Self.iso.string(from: at(daysAgo: 1, hour: 12)))",\
        "message":{"id":"msg_old","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1000,"output_tokens":10,"cache_read_input_tokens":0}}}
        """

        let record = try XCTUnwrap(JSONLAggregator.parseRecord(
            Data(line.utf8), projectSlug: alphaSlug,
            iso: Self.iso, isoNoFraction: Self.isoNoFraction, pool: &pool
        ))
        guard case .turn(let turn) = record else {
            return XCTFail("expected a turn, got \(record)")
        }
        XCTAssertEqual(turn.sessionID, "")
        XCTAssertEqual(turn.inputTokens, 1000)
    }
}
