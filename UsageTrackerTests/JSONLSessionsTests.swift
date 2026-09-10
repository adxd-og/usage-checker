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

    // MARK: - One chat's sums

    /// One chat: two main-thread turns yesterday, one the day before, and two
    /// sub-agents that ran yesterday.
    private func writeChatFixture() throws {
        try writeMain([
            mainTurn(id: "msg_m1", at: at(daysAgo: 2, hour: 9), input: 1_000_000),
            mainTurn(id: "msg_m2", at: at(daysAgo: 1, hour: 10), input: 1_000_000, output: 100_000),
            mainTurn(id: "msg_m3", at: at(daysAgo: 1, hour: 11), input: 1_000_000),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_a1", at: at(daysAgo: 1, hour: 10), agentID: "a06ceeae2762ca204",
                kind: "planner", input: 1_000_000
            )],
            agentID: "a06ceeae2762ca204"
        )
        try writeSubagent(
            [agentTurn(
                id: "msg_a2", at: at(daysAgo: 1, hour: 11), agentID: "aa4259fe7add3bfe9",
                kind: "test-verifier", model: "claude-sonnet-4-5", input: 2_000_000
            )],
            agentID: "aa4259fe7add3bfe9"
        )
    }

    func testAChatSumsItsMainThreadAndItsSubAgentsApart() async throws {
        try writeChatFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(chat.id, sessionID)
        XCTAssertEqual(chat.providerID, "claude")
        XCTAssertNil(chat.origin, "origin is Codex's field")
        XCTAssertEqual(chat.projectSlug, alphaSlug)
        XCTAssertEqual(chat.turns, 5, "three main-thread turns and two sub-agent turns")
        XCTAssertEqual(chat.tokens.input, 6_000_000, "the chat is the main thread plus its agents")
        XCTAssertEqual(chat.mainTokens.input, 3_000_000, "the main thread on its own")
        XCTAssertEqual(chat.mainTokens.output, 100_000)
        XCTAssertEqual(chat.firstAt, at(daysAgo: 2, hour: 9))
        XCTAssertEqual(chat.lastAt, at(daysAgo: 1, hour: 11))
        // Main thread on Sonnet: $3.00 + ($3.00 + $1.50 of output) + $3.00 = $10.50.
        // Agents: $5.00 for a million Opus input, $6.00 for two million Sonnet input.
        XCTAssertEqual(try XCTUnwrap(chat.tokens.cost).total, 21.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chat.mainTokens.cost).total, 10.5, accuracy: 1e-9)
    }

    func testAChatsSubAgentsAreListedByKindModelAndEffort() async throws {
        try writeChatFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.agents.map(\.kind), ["test-verifier", "planner"], "ranked by cost")
        XCTAssertEqual(chat.agents.map(\.id), ["aa4259fe7add3bfe9", "a06ceeae2762ca204"])
        XCTAssertEqual(chat.agents[0].model, "claude-sonnet-4-5")
        XCTAssertEqual(chat.agents[0].effort, "xhigh")
        XCTAssertEqual(chat.agents[0].turns, 1)
        XCTAssertEqual(chat.agents[0].tokens.input, 2_000_000)
        XCTAssertEqual(try XCTUnwrap(chat.agents[0].tokens.cost).total, 6.0, accuracy: 1e-9)
        XCTAssertEqual(chat.agents[1].model, "claude-opus-4-5")
        XCTAssertEqual(try XCTUnwrap(chat.agents[1].tokens.cost).total, 5.0, accuracy: 1e-9)
        XCTAssertEqual(
            chat.tokens.input,
            chat.mainTokens.input + chat.agents.reduce(0) { $0 + $1.tokens.input },
            "the chat's tokens are the main thread's plus every agent's"
        )
    }

    func testADayOfAChatIsOneRowHoweverManyTurnsItHolds() async throws {
        try writeChatFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 2), dayStart(daysAgo: 1)],
                       "ascending, one row per day and no per-turn rows at all")
        XCTAssertEqual(chat.days[0].turns, 1)
        XCTAssertEqual(chat.days[1].turns, 4, "two main-thread turns and two sub-agent turns")
        XCTAssertEqual(chat.days[1].tokens.input, 5_000_000)
        XCTAssertEqual(chat.turns, chat.days.reduce(0) { $0 + $1.turns })
    }

    func testARangeIsClippedToWholeLocalDays() async throws {
        try writeChatFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        // A range that starts in the middle of the day before yesterday still takes that
        // whole day: the aggregate keeps a day's sums, not a turn's.
        let sessions = await aggregator.sessions(
            from: at(daysAgo: 2, hour: 18), to: at(daysAgo: 1, hour: 10)
        )
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.count, 2, "both days the range touches, whole")
        XCTAssertEqual(chat.turns, 5)
        XCTAssertEqual(chat.tokens.input, 6_000_000)

        // And a range that touches only yesterday drops the older day outright.
        let narrow = await aggregator.sessions(
            from: at(daysAgo: 1, hour: 0), to: at(daysAgo: 1, hour: 23)
        )
        let clipped = try XCTUnwrap(narrow.first)

        XCTAssertEqual(clipped.days.map(\.day), [dayStart(daysAgo: 1)])
        XCTAssertEqual(clipped.turns, 4)
        XCTAssertEqual(clipped.tokens.input, 5_000_000)
        XCTAssertEqual(clipped.mainTokens.input, 2_000_000, "the main thread's share is clipped too")
        XCTAssertEqual(
            clipped.firstAt, at(daysAgo: 2, hour: 9),
            "only the counters are clipped — the chat still says when it started"
        )
    }

    func testAFiveHourWindowWidensToTheDayItFallsIn() async throws {
        try writeChatFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        // Five hours ending at 14:00 yesterday: no turn is inside it, both of
        // yesterday's are inside the day it falls in.
        let anchor = at(daysAgo: 1, hour: 14)
        let sessions = await aggregator.sessions(from: anchor.addingTimeInterval(-5 * 3600), to: anchor)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 1)])
        XCTAssertEqual(chat.turns, 4, "the window is a day, so the whole day counts")
    }

    func testAnAgentThatRanOutsideTheRangeIsNotListed() async throws {
        try writeChatFixture()
        // One more agent, on the older day, so the clip has something to drop.
        try writeSubagent(
            [agentTurn(
                id: "msg_a0", at: at(daysAgo: 2, hour: 9), agentID: "acfa466bf5542f6e0",
                kind: "executor", input: 500_000
            )],
            agentID: "acfa466bf5542f6e0"
        )
        let aggregator = aggregator()
        await aggregator.refresh()

        let wholeRange = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        let whole = try XCTUnwrap(wholeRange.first)
        XCTAssertEqual(Set(whole.agents.map(\.id)),
                       ["a06ceeae2762ca204", "aa4259fe7add3bfe9", "acfa466bf5542f6e0"])

        let yesterdayRange = await aggregator.sessions(
            from: at(daysAgo: 1, hour: 0), to: at(daysAgo: 1, hour: 23)
        )
        let yesterday = try XCTUnwrap(yesterdayRange.first)
        XCTAssertEqual(Set(yesterday.agents.map(\.id)), ["a06ceeae2762ca204", "aa4259fe7add3bfe9"],
                       "an agent whose whole run is outside the range is not in it")
    }

    func testAChatWithNoTurnInTheRangeIsNotListedAtAll() async throws {
        try writeChatFixture()
        try writeMain(
            [mainTurn(id: "msg_o1", at: at(daysAgo: 6, hour: 9), input: 1_000_000,
                      session: otherSessionID)],
            session: otherSessionID
        )
        let aggregator = aggregator()
        await aggregator.refresh()

        let recent = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        XCTAssertEqual(recent.map(\.id), [sessionID], "the six-day-old chat is outside the range")

        let both = await aggregator.sessions(from: dayStart(daysAgo: 7), to: now)
        XCTAssertEqual(both.map(\.id), [sessionID, otherSessionID], "newest chat first")

        let empty = await aggregator.sessions(from: dayStart(daysAgo: 5), to: dayStart(daysAgo: 4))
        XCTAssertTrue(empty.isEmpty, "no chat ran in those two days")
    }

    // MARK: - The last record for a message id

    /// Claude Code writes 2–4 assistant lines for one response under the same
    /// `message.id`: the first carries a provisional usage, the last the real counts.
    private func growingRecords(at date: Date) -> [String] {
        [
            mainTurn(id: "msg_grow", at: date, input: 1_000_000, output: 2, thinking: 0),
            mainTurn(id: "msg_grow", at: date, input: 1_000_000, output: 100_000, thinking: 40_000),
            mainTurn(id: "msg_grow", at: date, input: 1_000_000, output: 280_000, thinking: 149_000),
        ]
    }

    func testALaterRecordForAMessageIdRevisesTheChatsSums() async throws {
        try writeMain(growingRecords(at: at(daysAgo: 1, hour: 10)))
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.turns, 1, "one response is one turn, however many lines log it")
        XCTAssertEqual(chat.tokens.output, 280_000, "the final count, not the provisional 2")
        XCTAssertEqual(chat.mainTokens.output, 280_000)
        XCTAssertEqual(chat.days[0].tokens.output, 280_000)
        XCTAssertEqual(chat.tokens.input, 1_000_000, "counted once, not once per line")
        // $3.00 of input + $4.20 of output, following the replaced counts.
        XCTAssertEqual(try XCTUnwrap(chat.tokens.cost).total, 7.2, accuracy: 1e-9)
    }

    func testASubAgentsRevisedTurnFollowsTheAgentTooAndDoesNotRegress() async throws {
        // Provisional, final, then the provisional again — which a re-scanned tail or a
        // forked session can do. The rule is "later reading", not "last line seen".
        let when = at(daysAgo: 1, hour: 10)
        try writeSubagent(
            [
                agentTurn(id: "msg_ag", at: when, agentID: "a06ceeae2762ca204",
                          kind: "planner", input: 1_000_000, output: 2),
                agentTurn(id: "msg_ag", at: when, agentID: "a06ceeae2762ca204",
                          kind: "planner", input: 1_000_000, output: 200_000),
                agentTurn(id: "msg_ag", at: when, agentID: "a06ceeae2762ca204",
                          kind: "planner", input: 1_000_000, output: 2),
            ],
            agentID: "a06ceeae2762ca204"
        )
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.agents.count, 1)
        XCTAssertEqual(chat.agents[0].turns, 1)
        XCTAssertEqual(chat.agents[0].tokens.output, 200_000, "a smaller later record must not shrink it")
        XCTAssertEqual(chat.tokens.output, 200_000)
        XCTAssertEqual(chat.mainTokens.output, 0, "a sub-agent's tokens are not the main thread's")
    }

    /// The brief a sub-agent is started with: `type: user`, `isSidechain`, `agentId`,
    /// and — like every `type: user` record that is not the user — no `origin` at all.
    private func agentBriefLine(_ text: String, at date: Date, agentID: String,
                                session: String? = nil) -> String {
        """
        {"parentUuid":null,"isSidechain":true,\
        "promptId":"969c0b2a-d1a9-4869-9f04-4222ac5471dc","agentId":"\(agentID)",\
        "type":"user","message":{"role":"user","content":"\(text)"},\
        "uuid":"e355214c-92e0-4fcc-bfea-2f00341b4a4a",\
        "timestamp":"\(Self.iso.string(from: date))","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    // MARK: - The chat split by model

    /// A chat that ran on two models at two efforts with a sub-agent on a third: the
    /// shape a package day here really has — Sonnet at `high` for the cheap turns,
    /// Sonnet at `xhigh` and Opus for the expensive ones, and a Haiku sub-agent.
    private func writeModelFixture() throws {
        try writeMain([
            mainTurn(id: "msg_s1", at: at(daysAgo: 2, hour: 9),
                     model: "claude-sonnet-4-5", input: 1_000_000, effort: "high"),
            mainTurn(id: "msg_s2", at: at(daysAgo: 1, hour: 10),
                     model: "claude-sonnet-4-5", input: 1_000_000, output: 100_000,
                     effort: "xhigh"),
            mainTurn(id: "msg_o1", at: at(daysAgo: 1, hour: 11),
                     model: "claude-opus-4-5", input: 1_000_000, effort: "high"),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_a1", at: at(daysAgo: 1, hour: 11), agentID: "a06ceeae2762ca204",
                kind: "planner", model: "claude-haiku-4-5", input: 1_000_000, effort: "low"
            )],
            agentID: "a06ceeae2762ca204"
        )
    }

    func testAChatIsSplitByModelAndEffortWithItsSubAgentsIncluded() async throws {
        try writeModelFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 3), to: now)
        let chat = try XCTUnwrap(sessions.first)

        // Opus $5.00, Sonnet at xhigh $3.00 + $1.50, Sonnet at high $3.00, Haiku $1.00.
        XCTAssertEqual(
            chat.models.map(\.id),
            [
                "claude-opus-4-5|high",
                "claude-sonnet-4-5|xhigh",
                "claude-sonnet-4-5|high",
                "claude-haiku-4-5|low",
            ],
            "most expensive first"
        )
        XCTAssertEqual(chat.models.map(\.turns), [1, 1, 1, 1])
        XCTAssertEqual(chat.models[0].model, "claude-opus-4-5", "the raw id, not a display name")
        XCTAssertEqual(chat.models[0].effort, "high")
        XCTAssertEqual(try XCTUnwrap(chat.models[0].tokens.cost).total, 5.0, accuracy: 1e-9)
        XCTAssertEqual(chat.models[1].tokens.output, 100_000, "one model at two efforts is two rows")
        XCTAssertEqual(try XCTUnwrap(chat.models[1].tokens.cost).total, 4.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chat.models[2].tokens.cost).total, 3.0, accuracy: 1e-9)
        XCTAssertEqual(
            chat.models[3].model, "claude-haiku-4-5",
            "a sub-agent's model is one of the chat's models: the row says what the chat spent"
        )
        XCTAssertEqual(try XCTUnwrap(chat.models[3].tokens.cost).total, 1.0, accuracy: 1e-9)

        XCTAssertEqual(chat.models.reduce(0) { $0 + $1.turns }, chat.turns,
                       "every turn of the chat is in exactly one row")
        XCTAssertEqual(
            chat.models.reduce(TokenBreakdown.zero) { $0 + $1.tokens }.total,
            chat.tokens.total,
            "and so is every token"
        )
    }

    func testALaterRecordForAMessageIdDoesNotDoubleCountItsModel() async throws {
        // The provisional record, then two better ones for the same message id. The
        // row it landed in takes the difference; it must not take three turns or three
        // times the input.
        try writeMain(growingRecords(at: at(daysAgo: 1, hour: 10)))
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.models.map(\.id), ["claude-sonnet-4-5|high"], "one response, one row")
        XCTAssertEqual(chat.models[0].turns, 1, "a revision moves tokens, never turns")
        XCTAssertEqual(chat.models[0].tokens.input, 1_000_000, "counted once, not once per line")
        XCTAssertEqual(chat.models[0].tokens.output, 280_000, "the final count, not the provisional 2")
        XCTAssertEqual(chat.models[0].tokens.thinking, 149_000)
        XCTAssertEqual(try XCTUnwrap(chat.models[0].tokens.cost).total, 7.2, accuracy: 1e-9)
        XCTAssertEqual(chat.models[0].tokens, chat.tokens,
                       "a chat on one model spent all of it there")
    }

    func testAClippedRangeKeepsEveryModelRowWithTheChatsWholeTotals() async throws {
        try writeModelFixture()
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 1), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 1)], "one day survives the clip")
        XCTAssertEqual(chat.turns, 3, "and three of the four turns with it")
        XCTAssertEqual(chat.models.count, 4, "a model row is kept whenever any day is")
        XCTAssertEqual(
            chat.models.first { $0.id == "claude-sonnet-4-5|high" }?.tokens.input,
            1_000_000,
            "the row is the whole chat's: no per-model day split is stored"
        )
        XCTAssertEqual(
            chat.models.reduce(0) { $0 + $1.turns }, 4,
            "so the rows can outnumber the clipped chat's turns — the same rule agents follow"
        )
    }

    func testAChatsModelRowsSurviveARelaunch() async throws {
        try writeModelFixture()

        let first = aggregator(cache: cacheURL)
        await first.refresh()
        let firstSessions = await first.sessions(from: dayStart(daysAgo: 3), to: now)
        let before = try XCTUnwrap(firstSessions.first)

        let second = aggregator(cache: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let secondSessions = await second.sessions(from: dayStart(daysAgo: 3), to: now)
        let after = try XCTUnwrap(secondSessions.first)

        XCTAssertEqual(parsed, 0, "the cache answers without reopening a transcript")
        XCTAssertEqual(after.models.count, 4)
        XCTAssertEqual(after.models, before.models, "keys, efforts, turns and per-category dollars")
    }

    // MARK: - The chat's name

    func testATitleIsCollapsedAndCutAtEightyCharacters() {
        XCTAssertEqual(SessionTitle.collapse("  Ledger   0.3.3\n"), "Ledger 0.3.3")
        XCTAssertEqual(
            SessionTitle.collapse("Привет!\nМожет нам в нашу туллу добавить такое?)"),
            "Привет! Может нам в нашу туллу добавить такое?)",
            "a newline in the middle of a prompt is one space, not a broken row"
        )
        XCTAssertNil(SessionTitle.collapse("   \n\t "), "whitespace is not a name")
        XCTAssertNil(SessionTitle.collapse(""))

        let long = String(repeating: "a", count: 200)
        let cut = try? XCTUnwrap(SessionTitle.collapse(long))
        XCTAssertEqual(cut?.count, 80, "eighty characters including the ellipsis")
        XCTAssertEqual(cut?.last, "…")

        // The cut lands mid-word: no dangling space before the ellipsis.
        let sentence = String(repeating: "word ", count: 40)
        XCTAssertFalse(
            (SessionTitle.collapse(sentence) ?? "").hasSuffix(" …"),
            "a space before the ellipsis is a typographic accident"
        )
    }

    func testAContentArrayIsReadAsItsTextParts() {
        XCTAssertEqual(
            SessionTitle.firstPrompt(from: [
                ["type": "text", "text": "Прочитай"],
                ["type": "image", "source": ["type": "base64"]],
                ["type": "text", "text": "леджер"],
            ] as [[String: Any]]),
            "Прочитай леджер"
        )
        XCTAssertEqual(SessionTitle.firstPrompt(from: "плоская строка"), "плоская строка")
        XCTAssertNil(SessionTitle.firstPrompt(from: 42))
        XCTAssertNil(SessionTitle.firstPrompt(from: nil))
    }

    func testTheAiTitleNamesTheChatAndTheLastOneWins() async throws {
        try writeMain([
            humanPromptLine("Привет! прочитай леджер 0.3.3)", at: at(daysAgo: 1, hour: 9)),
            titleLine("Ledger"),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 10), input: 1_000_000),
            titleLine("Ledger 0.3.3"),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.title, "Ledger 0.3.3", "a chat carries many ai-titles; the last wins")
    }

    func testWithoutAnAiTitleTheFirstHumanPromptNamesTheChat() async throws {
        try writeMain([
            // The `<local-command-caveat>` record comes first and is not the user talking.
            metaUserLine(at: at(daysAgo: 1, hour: 8)),
            humanPromptLine("Привет! прочитай леджер 0.3.3)", at: at(daysAgo: 1, hour: 9)),
            humanPromptLine("И ещё раз", at: at(daysAgo: 1, hour: 11)),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 10), input: 1_000_000),
        ])
        // A sub-agent's brief is a `type: user` record too, and never names the chat —
        // it carries the same `sessionId` and would otherwise win, being read first
        // whenever the enumerator reaches the sub-agent's transcript before the main one.
        try writeSubagent(
            [
                agentBriefLine("Write the plan for package P1", at: at(daysAgo: 1, hour: 9),
                               agentID: "a06ceeae2762ca204"),
                agentTurn(id: "msg_a1", at: at(daysAgo: 1, hour: 10),
                          agentID: "a06ceeae2762ca204", kind: "planner", input: 1_000),
            ],
            agentID: "a06ceeae2762ca204"
        )
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.title, "Привет! прочитай леджер 0.3.3)", "the first human prompt, not the second")
    }

    func testAChatWithNeitherNameHasNoTitle() async throws {
        try writeMain([
            metaUserLine(at: at(daysAgo: 1, hour: 8)),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 10), input: 1_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertNil(chat.title, "the caveat record is the tool talking to itself")
    }

    // MARK: - The on-disk cache

    func testAChatSurvivesARelaunchWithoutReopeningATranscript() async throws {
        try writeChatFixture()
        try writeMain([
            mainTurn(id: "msg_m1", at: at(daysAgo: 2, hour: 9), input: 1_000_000),
            mainTurn(id: "msg_m2", at: at(daysAgo: 1, hour: 10), input: 1_000_000, output: 100_000),
            mainTurn(id: "msg_m3", at: at(daysAgo: 1, hour: 11), input: 1_000_000),
            titleLine("Ledger 0.3.3"),
        ])

        let first = aggregator(cache: cacheURL)
        await first.refresh()
        let firstSessions = await first.sessions(from: dayStart(daysAgo: 3), to: now)
        let before = try XCTUnwrap(firstSessions.first)

        let second = aggregator(cache: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let secondSessions = await second.sessions(from: dayStart(daysAgo: 3), to: now)
        let after = try XCTUnwrap(secondSessions.first)

        XCTAssertEqual(parsed, 0, "the cache answers without reopening a transcript")
        XCTAssertEqual(after, before, "every field, agents, days and per-category dollars included")
        XCTAssertEqual(after.title, "Ledger 0.3.3", "the name is cached with the chat")
    }

    func testAVersionFourCacheIsRejectedAndTheChatsAreReadAgain() async throws {
        try writeChatFixture()

        // A snapshot in the *current* shape wearing the old version number, carrying a
        // chat the logs cannot produce. Only the version check can reject it — a decode
        // failure would prove nothing about the bump.
        func snapshot(version: Int) -> Data {
            let tokens: [String: Any] = [
                "input": 7_777, "output": 0, "cacheRead": 0,
                "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
            ]
            let object: [String: Any] = [
                "version": version,
                "root": root.path,
                "savedAt": ISO8601DateFormatter().string(from: now),
                "fileMarks": [String: Any](),
                "recentTurns": [Any](),
                "oldDays": [Any](),
                "seenMessageIDs": [Any](),
                "sessions": [
                    "ffffffff-0000-0000-0000-000000000000": [
                        "projectSlug": alphaSlug,
                        "firstAt": ISO8601DateFormatter().string(from: at(daysAgo: 1, hour: 9)),
                        "lastAt": ISO8601DateFormatter().string(from: at(daysAgo: 1, hour: 9)),
                        "days": [[
                            "day": ISO8601DateFormatter().string(from: dayStart(daysAgo: 1)),
                            "turns": 77,
                            "tokens": tokens,
                            "mainTokens": tokens,
                        ]],
                        "agents": [String: Any](),
                        "byModel": [
                            "claude-sonnet-4-5|high": [
                                "model": "claude-sonnet-4-5",
                                "effort": "high",
                                "turns": 77,
                                "tokens": tokens,
                            ],
                        ],
                    ],
                ],
                "titles": ["ffffffff-0000-0000-0000-000000000000": "A chat from the old cache"],
                "firstPrompts": [String: Any](),
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        try snapshot(version: 4).write(to: cacheURL)
        let stale = aggregator(cache: cacheURL)
        await stale.refresh()
        let staleParsed = await stale.filesParsedInLastScan
        let staleSessions = await stale.sessions(from: dayStart(daysAgo: 3), to: now)

        XCTAssertEqual(staleParsed, 3, "a version-4 snapshot means a full rescan of all three transcripts")
        XCTAssertEqual(staleSessions.map(\.id), [sessionID], "nothing from the old snapshot reaches the list")

        // The control: the same bytes at version 5 ARE restored, so the assertions above
        // are about the version number and not about an unreadable file.
        let currentURL = cacheFile(named: "control")
        try snapshot(version: 5).write(to: currentURL)
        let current = aggregator(cache: currentURL)
        await current.refresh()
        let restored = await current.sessions(from: dayStart(daysAgo: 3), to: now)

        let old = try XCTUnwrap(restored.first { $0.title == "A chat from the old cache" })
        XCTAssertEqual(old.turns, 77, "a current snapshot restores its chats, names and all")
        XCTAssertEqual(old.models.map(\.id), ["claude-sonnet-4-5|high"], "model rows included")
        XCTAssertEqual(old.models.first?.turns, 77)
    }

    // MARK: - Retention

    func testAChatWhoseLastTurnIsOlderThanNinetyTwoDaysIsDropped() async throws {
        // The file is new, so the ninety-day mtime window still lets the scanner read
        // it; only the records are old.
        try writeMain(
            [
                humanPromptLine("Очень старый чат", at: at(daysAgo: 100, hour: 9),
                                session: otherSessionID),
                mainTurn(id: "msg_ancient", at: at(daysAgo: 100, hour: 10), input: 1_000_000,
                         session: otherSessionID),
            ],
            session: otherSessionID
        )
        try writeMain([mainTurn(id: "msg_recent", at: at(daysAgo: 1, hour: 10), input: 1_000_000)])

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: at(daysAgo: 200, hour: 0), to: now)

        XCTAssertEqual(sessions.map(\.id), [sessionID], "a chat is kept for 92 days after its last turn")
    }

    func testALivingChatDropsOnlyItsDaysPastTheWindow() async throws {
        try writeMain([
            mainTurn(id: "msg_ancient", at: at(daysAgo: 100, hour: 10), input: 1_000_000),
            mainTurn(id: "msg_recent", at: at(daysAgo: 1, hour: 10), input: 2_000_000),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_old_agent", at: at(daysAgo: 100, hour: 11),
                agentID: "acfa466bf5542f6e0", kind: "executor", input: 1_000_000
            )],
            agentID: "acfa466bf5542f6e0"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: at(daysAgo: 200, hour: 0), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 1)], "the hundred-day-old day is gone")
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.tokens.input, 2_000_000)
        XCTAssertTrue(chat.agents.isEmpty, "so is the agent that only ran that day")
        XCTAssertEqual(chat.firstAt, at(daysAgo: 100, hour: 10), "the chat still says when it started")
    }
}
