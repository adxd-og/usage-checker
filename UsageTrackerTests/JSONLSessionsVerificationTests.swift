import XCTest
@testable import Omelette

/// Independent verification of the Claude half of Sessions in History: spec
/// `docs/superpowers/specs/2026-09-10-sessions-history-design.md` § 1's
/// `sessions(from:to:)` contract, § 2 (`JSONLAggregator`), and § 6.
///
/// Written from the spec and the production diff, not from the executor's own
/// `JSONLSessionsTests.swift` — no fixture, helper or assertion here is copied from
/// it. The fixture lines are shapes copied from this Mac's own
/// `~/.claude/projects` logs (ids, paths and prompt text scrubbed), including the
/// `subagents/workflows/wf_<hash>/agent-<id>.jsonl` shape a real workflow run writes.
///
/// Every date test pins its own calendar to a fixed +3:00 offset — deliberately not
/// UTC and not the host machine's zone — so a bug that quietly hardcodes UTC day
/// boundaries would show up here even though the executor's own tests (pinned to
/// UTC) would not catch it.
final class JSONLSessionsVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let sessionID = "b2f6a4e1-6d8f-4b1a-9a2b-2f6a4e16d8f4"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let betaSlug = "-Users-tester-Projects-beta"

    /// Fixed +3:00, no DST — a "local" day genuinely offset from UTC, so the
    /// day-binning logic is exercised for real rather than trivially agreeing with UTC.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLSessionsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: cacheFile(named: "control"))
    }

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

    private func at(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: dayStart(daysAgo: daysAgo))!
    }

    private func dayStart(daysAgo: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    // MARK: - Fixture records

    private func mainTurn(
        id: String, at date: Date, model: String = "claude-sonnet-4-5",
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreate5m: Int = 0,
        thinking: Int = 0, effort: String = "high", session: String? = nil
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

    /// `kind: nil` omits `attributionAgent` entirely, for the fallback test.
    private func agentTurn(
        id: String, at date: Date, agentID: String, kind: String?,
        model: String = "claude-opus-4-5", input: Int = 0, output: Int = 0,
        effort: String = "xhigh", session: String? = nil
    ) -> String {
        let attributionAgentField = kind.map { "\"attributionAgent\":\"\($0)\"," } ?? ""
        return """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CeqhfbvWNe5EU6Yax6z9r",\(attributionAgentField)\
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

    /// `originKind`/`promptSource` are both overridable so one helper covers the human
    /// prompt, a task-notification `type: user` record, and the SDK-driven cases.
    private func humanPromptLine(
        _ text: String, at date: Date, session: String? = nil,
        originKind: String = "human", promptSource: String = "typed"
    ) -> String {
        """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":"\(text)"},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: date))","permissionMode":"auto",\
        "origin":{"kind":"\(originKind)"},"promptSource":"\(promptSource)","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    /// `message.content` as `[{"type":"text",...}]`, an image part mixed in — the shape
    /// § Facts says the logs also allow.
    private func arrayContentPromptLine(textParts: [String], at date: Date, session: String? = nil) -> String {
        let parts = textParts.map { "{\"type\":\"text\",\"text\":\"\($0)\"}" }.joined(separator: ",")
        return """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":[\(parts),{"type":"image","source":{"type":"base64"}}]},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: date))","permissionMode":"auto",\
        "origin":{"kind":"human"},"promptSource":"typed","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session ?? sessionID)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    // MARK: - Fixture files

    private func writeMain(_ lines: [String], session: String? = nil, project: String? = nil) throws {
        let dir = root.appendingPathComponent(project ?? alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session ?? sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

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

    /// `<slug>/<sessionId>/subagents/workflows/wf_<hash>/agent-<id>.jsonl` — two levels
    /// deeper than `writeSubagent`, exactly where this Mac's own logs put a workflow's
    /// sub-agent transcript.
    private func writeWorkflowSubagent(
        _ lines: [String], agentID: String, workflowHash: String,
        session: String? = nil, project: String? = nil
    ) throws {
        let dir = root
            .appendingPathComponent(project ?? alphaSlug, isDirectory: true)
            .appendingPathComponent(session ?? sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent(workflowHash, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func aggregator(cache: URL? = nil, saveInterval: TimeInterval = 0) -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cache, saveInterval: saveInterval, calendar: calendar)
    }

    // MARK: - A workflow sub-agent, two levels deeper than `subagents/`

    func testAWorkflowSubAgentTwoLevelsDeeperStillBelongsToItsProjectAndChat() async throws {
        try writeMain([mainTurn(id: "msg_main", at: at(daysAgo: 1, hour: 9), input: 1_000_000)])
        try writeWorkflowSubagent(
            [agentTurn(
                id: "msg_wf", at: at(daysAgo: 1, hour: 10), agentID: "af00d540dc861081",
                kind: "reviewer", input: 500_000
            )],
            agentID: "af00d540dc861081", workflowHash: "wf_540dc861-081"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.projectSlug, alphaSlug, "the log root's own child, not `workflows` or `wf_...`")
        XCTAssertEqual(chat.agents.map(\.id), ["af00d540dc861081"])
        XCTAssertEqual(chat.agents[0].kind, "reviewer")
        XCTAssertEqual(chat.tokens.input, 1_500_000)
    }

    // MARK: - Day-granularity clipping across local days

    func testASessionOnThreeLocalDaysClippedToTheMiddleDayOnly() async throws {
        try writeMain([
            mainTurn(id: "msg_d3", at: at(daysAgo: 3, hour: 10), input: 1_000_000),
            mainTurn(id: "msg_d2", at: at(daysAgo: 2, hour: 10), input: 2_000_000),
            mainTurn(id: "msg_d1", at: at(daysAgo: 1, hour: 10), input: 4_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(
            from: at(daysAgo: 2, hour: 0), to: at(daysAgo: 2, hour: 23)
        )
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 2)], "only the middle day survives the clip")
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.tokens.input, 2_000_000)
        XCTAssertEqual(chat.firstAt, at(daysAgo: 3, hour: 10), "firstAt is never clipped")
        XCTAssertEqual(chat.lastAt, at(daysAgo: 1, hour: 10), "lastAt is never clipped either")
    }

    func testAFiveHourWindowStraddlingLocalMidnightCountsBothDays() async throws {
        try writeMain([
            mainTurn(id: "msg_before", at: at(daysAgo: 2, hour: 22), input: 1_000_000),
            mainTurn(id: "msg_after", at: at(daysAgo: 1, hour: 0).addingTimeInterval(30 * 60), input: 3_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        // 20:00 the day before yesterday to 01:00 yesterday: five hours, straddling the
        // local midnight between the two days.
        let sessions = await aggregator.sessions(
            from: at(daysAgo: 2, hour: 20), to: at(daysAgo: 1, hour: 1)
        )
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(
            chat.days.map(\.day), [dayStart(daysAgo: 2), dayStart(daysAgo: 1)],
            "both local days the window straddles"
        )
        XCTAssertEqual(chat.turns, 2)
        XCTAssertEqual(chat.tokens.input, 4_000_000)
    }

    // MARK: - mainTokens vs. tokens, every category

    func testMainTokensExcludesEveryAgentCategoryWhenAgentsExist() async throws {
        try writeMain([
            mainTurn(
                id: "msg_main1", at: at(daysAgo: 1, hour: 9),
                input: 100_000, output: 20_000, cacheRead: 5_000, cacheCreate5m: 3_000, thinking: 1_000
            ),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_agent1", at: at(daysAgo: 1, hour: 10), agentID: "agent-mix",
                kind: "executor", input: 50_000, output: 10_000
            )],
            agentID: "agent-mix"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.mainTokens.input, 100_000)
        XCTAssertEqual(chat.mainTokens.output, 20_000)
        XCTAssertEqual(chat.mainTokens.cacheRead, 5_000)
        XCTAssertEqual(chat.mainTokens.cacheWrite5m, 3_000)
        XCTAssertEqual(chat.mainTokens.thinking, 1_000)

        XCTAssertEqual(chat.tokens.input, 150_000, "main plus the agent")
        XCTAssertEqual(chat.tokens.output, 30_000)
        XCTAssertEqual(chat.tokens.cacheRead, 5_000, "the agent turn carries none of its own")
        XCTAssertEqual(chat.tokens.thinking, 1_000, "the agent turn carries none of its own")
    }

    // MARK: - A title arriving before any turn

    func testAnAiTitleArrivingBeforeAnyTurnIsAdoptedOnceTheChatExists() async throws {
        // First poll: only the title, no assistant record yet for this chat.
        try writeMain([titleLine("Early title, no chat yet")])
        let aggregator = aggregator()
        await aggregator.refresh()
        let before = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        XCTAssertTrue(before.isEmpty, "a title with no turn behind it names no chat")

        // Next poll's chunk: the title line unchanged (so the scan can treat this as an
        // append) plus the turn that finally creates the chat.
        try writeMain([
            titleLine("Early title, no chat yet"),
            mainTurn(id: "msg_after_title", at: at(daysAgo: 1, hour: 10), input: 1_000_000),
        ])
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.title, "Early title, no chat yet", "the title is remembered until the chat exists")
    }

    // MARK: - First human prompt: array content, and origin/promptSource variants

    func testAFirstPromptWithArrayContentPartsNamesTheChat() async throws {
        try writeMain([
            arrayContentPromptLine(
                textParts: ["Прочитай", "леджер"], at: at(daysAgo: 1, hour: 8)
            ),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.title, "Прочитай леджер", "the text parts joined, the image part dropped")
    }

    func testATaskNotificationOriginIsNeverTakenAsTheFirstPrompt() async throws {
        try writeMain([
            humanPromptLine(
                "A task finished elsewhere", at: at(daysAgo: 1, hour: 8),
                originKind: "task-notification"
            ),
            humanPromptLine("The real first thing I asked", at: at(daysAgo: 1, hour: 9)),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 10), input: 1_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.title, "The real first thing I asked")
    }

    func testAnOriginKindOtherThanHumanIsNeverTakenAsTheFirstPrompt() async throws {
        // A literal `origin.kind == "sdk"` record — never observed on this Mac, but the
        // guard checks equality to "human" and must reject any other value the same way.
        try writeMain([
            humanPromptLine("Not the user talking", at: at(daysAgo: 1, hour: 8), originKind: "sdk"),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertNil(chat.title, "no other name is available")
    }

    func testAPromptSentThroughTheSdkIsStillTakenWhenOriginIsHuman() async throws {
        // Decision 13: promptSource is not part of the rule. A session launched through
        // the SDK still carries origin.kind == "human" on a prompt the user really typed.
        try writeMain([
            humanPromptLine(
                "Typed by a real person, relayed by the SDK", at: at(daysAgo: 1, hour: 8),
                originKind: "human", promptSource: "sdk"
            ),
            mainTurn(id: "msg_m1", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(
            chat.title, "Typed by a real person, relayed by the SDK",
            "promptSource must not exclude a human-origin prompt"
        )
    }

    // MARK: - A later record never shrinks a turn, main thread included

    func testAMainThreadTurnNeverShrinksEvenIfAStaleRecordArrivesLast() async throws {
        let when = at(daysAgo: 1, hour: 10)
        try writeMain([
            mainTurn(id: "msg_main_grow", at: when, input: 1_000_000, output: 5),
            mainTurn(id: "msg_main_grow", at: when, input: 1_000_000, output: 300_000),
            mainTurn(id: "msg_main_grow", at: when, input: 1_000_000, output: 5),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        XCTAssertEqual(chat.turns, 1, "one message id, one turn")
        XCTAssertEqual(chat.tokens.output, 300_000, "the peak record, not the stale one replayed last")
        XCTAssertEqual(chat.mainTokens.output, 300_000)
        XCTAssertEqual(chat.days[0].tokens.output, 300_000)
    }

    // MARK: - Cache v4: round trip, and a v3 file discarded

    func testCacheV4RestoresSessionsTitlesAndFirstPromptsWithTheLogsDeleted() async throws {
        try writeMain([
            humanPromptLine("Читаем кэш версии четыре", at: at(daysAgo: 2, hour: 8)),
            mainTurn(id: "msg_c1", at: at(daysAgo: 2, hour: 9), input: 1_000_000),
            mainTurn(id: "msg_c2", at: at(daysAgo: 1, hour: 9), input: 500_000, output: 20_000),
            titleLine("Кэш v4"),
        ])
        try writeSubagent(
            [agentTurn(
                id: "msg_ca1", at: at(daysAgo: 1, hour: 10), agentID: "agent-cache-1",
                kind: "planner", input: 200_000
            )],
            agentID: "agent-cache-1"
        )

        let first = aggregator(cache: cacheURL)
        await first.refresh()
        await first.flushCache()
        let beforeSessions = await first.sessions(from: dayStart(daysAgo: 3), to: now)
        let before = try XCTUnwrap(beforeSessions.first)

        // Delete every transcript: the second aggregator must answer from the cache alone.
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let second = aggregator(cache: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let afterSessions = await second.sessions(from: dayStart(daysAgo: 3), to: now)
        let after = try XCTUnwrap(afterSessions.first)

        XCTAssertEqual(parsed, 0, "nothing left to scan; the cache alone answers")
        XCTAssertEqual(after, before, "every field — agents, days, per-category dollars — round-trips")
        XCTAssertEqual(after.title, "Кэш v4")
        XCTAssertEqual(after.agents.map(\.id), ["agent-cache-1"])
    }

    func testARealV4CacheRewrittenAsV3IsDiscardedWholesaleAndTheLogsAreReRead() async throws {
        try writeMain([mainTurn(id: "msg_v3a", at: at(daysAgo: 1, hour: 9), input: 1_000_000)])
        let first = aggregator(cache: cacheURL)
        await first.refresh()
        await first.flushCache()

        // Patch a real, valid v4 snapshot's version number down to 3 in place — the
        // control that a decode failure is not what's rejecting it.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as! [String: Any]
        json["version"] = 3
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)

        // A second turn, so the rescan is distinguishable from a snapshot that was
        // silently accepted.
        try writeMain([
            mainTurn(id: "msg_v3a", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
            mainTurn(id: "msg_v3b", at: at(daysAgo: 1, hour: 11), input: 2_000_000),
        ])

        let reloaded = aggregator(cache: cacheURL)
        await reloaded.refresh()
        let parsed = await reloaded.filesParsedInLastScan
        let reloadedSessions = await reloaded.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(reloadedSessions.first)

        XCTAssertEqual(parsed, 1, "a version-3 snapshot means the one transcript is read again")
        XCTAssertEqual(chat.turns, 2, "both turns recovered by the rescan")
        XCTAssertEqual(chat.tokens.input, 3_000_000)
    }

    // MARK: - Retention at the 92-day boundary

    func testASessionExactlyNinetyTwoDaysOldSurvivesButNinetyThreeDoesNot() async throws {
        let survivor = "survivor-92-days"
        let dropped = "dropped-93-days"
        try writeMain(
            [mainTurn(id: "msg_92", at: at(daysAgo: 92, hour: 3), input: 1_000_000, session: survivor)],
            session: survivor
        )
        try writeMain(
            [mainTurn(id: "msg_93", at: at(daysAgo: 93, hour: 21), input: 1_000_000, session: dropped)],
            session: dropped
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: at(daysAgo: 200, hour: 0), to: now)

        XCTAssertTrue(
            sessions.map(\.id).contains(survivor),
            "92 days is still inside the window (92 > 90 History reaches)"
        )
        XCTAssertFalse(
            sessions.map(\.id).contains(dropped),
            "one calendar day further back falls outside it"
        )
    }

    // MARK: - Per-category dollars

    func testCostPerCategoryIsPresentOnTheChatsTokensCost() async throws {
        try writeMain([
            mainTurn(
                id: "msg_cost1", at: at(daysAgo: 1, hour: 9),
                input: 1_000_000, output: 200_000, cacheRead: 500_000, cacheCreate5m: 100_000
            ),
        ])
        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)
        let cost = try XCTUnwrap(chat.tokens.cost)

        // claude-sonnet-4-5: $3/M input, $15/M output, $0.3/M cache read, $3.75/M 5m write.
        XCTAssertEqual(cost.input, 3.0, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 3.0, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 0.15, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheWrite, 0.375, accuracy: 1e-9)
        XCTAssertEqual(cost.total, cost.input + cost.output + cost.cacheRead + cost.cacheWrite, accuracy: 1e-9)
    }

    // MARK: - A turn with no sessionId

    func testATurnWithNoSessionIdCountsToUsageButJoinsNoChat() async throws {
        let orphanLine = """
        {"type":"assistant","timestamp":"\(Self.iso.string(from: at(daysAgo: 1, hour: 10)))",\
        "message":{"id":"msg_orphan","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":500000,"output_tokens":0,"cache_read_input_tokens":0}}}
        """
        try writeMain([
            mainTurn(id: "msg_has_session", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
            orphanLine,
        ])

        let aggregator = aggregator()
        await aggregator.refresh()

        let usage = await aggregator.usage(from: at(daysAgo: 2, hour: 0), to: now)
        XCTAssertEqual(usage.turns, 2, "the session-less turn still counts towards the window totals")

        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].turns, 1, "only the turn that carries a sessionId belongs to a chat")
    }

    // MARK: - Two projects, one calendar day

    func testTwoSessionsInDifferentProjectsOnTheSameDayAreListedSeparately() async throws {
        let alpha = "same-day-alpha-session"
        let beta = "same-day-beta-session"
        try writeMain(
            [mainTurn(id: "msg_alpha", at: at(daysAgo: 1, hour: 9), input: 1_000_000, session: alpha)],
            session: alpha, project: alphaSlug
        )
        try writeMain(
            [mainTurn(id: "msg_beta", at: at(daysAgo: 1, hour: 10), input: 2_000_000, session: beta)],
            session: beta, project: betaSlug
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)

        XCTAssertEqual(Set(sessions.map(\.id)), [alpha, beta])
        let alphaChat = try XCTUnwrap(sessions.first { $0.id == alpha })
        let betaChat = try XCTUnwrap(sessions.first { $0.id == beta })
        XCTAssertEqual(alphaChat.projectSlug, alphaSlug)
        XCTAssertEqual(betaChat.projectSlug, betaSlug)
        XCTAssertEqual(alphaChat.tokens.input, 1_000_000)
        XCTAssertEqual(betaChat.tokens.input, 2_000_000)
        XCTAssertEqual(
            alphaChat.days.map(\.day), betaChat.days.map(\.day),
            "the same calendar day, in two different projects, are not the same row"
        )
    }

    // MARK: - Agent kind fallback

    func testAnAgentWithNoAttributionAgentFallsBackToTheLiteralSubAgent() async throws {
        try writeSubagent(
            [agentTurn(
                id: "msg_no_kind", at: at(daysAgo: 1, hour: 10), agentID: "agent-no-kind",
                kind: nil, input: 1_000
            )],
            agentID: "agent-no-kind"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.agents.map(\.kind), ["sub-agent"])
    }

    // MARK: - Deterministic tie-breaks

    func testSessionsWithEqualLastAtAreOrderedByIdAscending() async throws {
        let when = at(daysAgo: 1, hour: 10)
        let idHigh = "zzzz-tie-session"
        let idLow = "aaaa-tie-session"
        try writeMain([mainTurn(id: "msg_a", at: when, input: 1_000, session: idHigh)], session: idHigh)
        try writeMain([mainTurn(id: "msg_b", at: when, input: 1_000, session: idLow)], session: idLow)

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)

        XCTAssertEqual(sessions.map(\.id), [idLow, idHigh], "identical lastAt, ascending by id")
    }

    func testAgentsWithEqualCostAreOrderedByIdAscending() async throws {
        let when = at(daysAgo: 1, hour: 10)
        try writeSubagent(
            [agentTurn(id: "msg_z", at: when, agentID: "zzzz-tie-agent", kind: "k1", input: 1_000)],
            agentID: "zzzz-tie-agent"
        )
        try writeSubagent(
            [agentTurn(id: "msg_a", at: when, agentID: "aaaa-tie-agent", kind: "k2", input: 1_000)],
            agentID: "aaaa-tie-agent"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.agents.map(\.id), ["aaaa-tie-agent", "zzzz-tie-agent"], "identical cost, ascending by id")
    }

    // MARK: - An agent whole or absent, never clipped

    func testAnAgentThatStartedBeforeTheRangeButRanIntoItIsIncludedWhole() async throws {
        try writeMain([
            mainTurn(id: "msg_m1", at: at(daysAgo: 3, hour: 9), input: 1_000_000),
            mainTurn(id: "msg_m2", at: at(daysAgo: 1, hour: 9), input: 1_000_000),
        ])
        // The agent's first turn is outside the range that will be queried; its last is
        // inside it.
        try writeSubagent(
            [
                agentTurn(
                    id: "msg_a1", at: at(daysAgo: 3, hour: 10), agentID: "spanning-agent",
                    kind: "planner", input: 500_000
                ),
                agentTurn(
                    id: "msg_a2", at: at(daysAgo: 1, hour: 10), agentID: "spanning-agent",
                    kind: "planner", input: 700_000
                ),
            ],
            agentID: "spanning-agent"
        )

        let aggregator = aggregator()
        await aggregator.refresh()
        // A range covering only the last two days, not the agent's first turn's day.
        let sessions = await aggregator.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(
            chat.agents.map(\.id), ["spanning-agent"],
            "its lastAt overlaps the range even though its firstAt does not"
        )
        XCTAssertEqual(
            chat.agents[0].tokens.input, 1_200_000,
            "the agent's full totals, not clipped to the range"
        )
    }
}
