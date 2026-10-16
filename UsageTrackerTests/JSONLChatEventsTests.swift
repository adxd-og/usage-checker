import XCTest
@testable import Omelette

/// Claude's chat events for the Limits tab's stretches: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5 ("a new stretch
/// starts at a Claude Code `compact_boundary` record … as its name the first human prompt
/// after the boundary") and § Packages 3 ("needs the aggregators to keep compaction times …
/// and first prompts"). The lines are the shapes `~/.claude/projects` holds on this Mac
/// (Claude Code 2.1.257 to 2.1.263), ids, names and paths scrubbed:
/// - `compact_boundary` on the chat's own thread (`isSidechain` false), and in a
///   sub-agent's transcript (`isSidechain` true, `agentId`), where it is the agent's;
/// - the summary Claude Code writes after a compaction: a `user` record with no `origin`;
/// - prompts the user typed (`origin.kind == "human"`).
///
/// Dates are relative to the real clock: the aggregator keeps what is younger than its
/// 31-day turn horizon by `Date()`.
final class JSONLChatEventsTests: XCTestCase {
    private var root: URL!
    /// Whole seconds, so a timestamp survives the fixture's format/parse round trip.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private let chatA = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let chatB = "90a2e89b-86f7-438b-bbb1-d0b5735809e3"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let agentID = "a7f80c42893fb9281"

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLChatEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: - Fixture records

    /// A main-thread assistant record (Claude Code 2.1.263), content elided: $0.003 of Sonnet input.
    private func mainTurn(id: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":1000,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "service_tier":"standard"}},"apiBlockIndex":0,\
        "requestId":"req_011CenRuxq86v1VeS6TBkZqi","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"high",\
        "session_id":"\(session)","userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session)","version":"2.1.263",\
        "gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    /// A sub-agent's assistant record: `isSidechain`, `agentId`, the parent's `sessionId`.
    private func agentTurn(id: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CeqhfbvWNe5EU6Yax6z9r","attributionAgent":"planner",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.263","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"claude-opus-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":1000,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":0,"service_tier":"standard"}}}
        """
    }

    /// `compact_boundary` on the chat's own thread (Claude Code 2.1.257, `/compact`).
    private func compaction(at date: Date, session: String) -> String {
        """
        {"parentUuid":null,"logicalParentUuid":"d1b77e27-5917-462f-8c04-4163d9c86dd9",\
        "isSidechain":false,"type":"system","subtype":"compact_boundary",\
        "content":"Conversation compacted","level":"info",\
        "compactMetadata":{"trigger":"manual","preTokens":926842,"postTokens":25865},\
        "uuid":"250ddee4-8119-47db-a7a0-ad2d86929b99","timestamp":"\(Self.iso.string(from: date))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.257","gitBranch":"main","slug":"keen-meandering-nest"}
        """
    }

    /// The same record in a sub-agent's transcript: `isSidechain`, the agent's id, `auto`.
    private func agentCompaction(at date: Date, session: String) -> String {
        """
        {"parentUuid":null,"logicalParentUuid":"9b1d5e0c-6f2a-4d3e-8c7b-1a2b3c4d5e6f",\
        "isSidechain":true,"agentId":"\(agentID)","type":"system","subtype":"compact_boundary",\
        "content":"Conversation compacted","level":"info",\
        "compactMetadata":{"trigger":"auto","preTokens":412000,"postTokens":31000},\
        "uuid":"7d6c5b4a-3e2f-4a1b-9c8d-0e1f2a3b4c5d","timestamp":"\(Self.iso.string(from: date))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    /// The summary Claude Code writes right after a compaction: a `user` record with no
    /// `origin`, which the user never typed.
    private func compactSummary(at date: Date, session: String) -> String {
        """
        {"parentUuid":"250ddee4-8119-47db-a7a0-ad2d86929b99","isSidechain":false,\
        "promptId":"f1c11245-6eeb-4b4d-9d0a-aa29b94bb108","type":"user",\
        "message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."},\
        "isVisibleInTranscriptOnly":true,"isCompactSummary":true,\
        "uuid":"1277c4f6-52a7-4cdf-b6fe-783b5713d680","timestamp":"\(Self.iso.string(from: date))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.257","gitBranch":"main","slug":"keen-meandering-nest"}
        """
    }

    /// A prompt the user typed: `origin.kind == "human"`.
    private func humanPrompt(_ text: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":"\(text)"},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: date))","permissionMode":"auto",\
        "origin":{"kind":"human"},"promptSource":"typed","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    // MARK: - Fixture files

    private func writeMain(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    /// `<project>/<sessionId>/subagents/agent-<id>.jsonl`, where Claude Code puts a
    /// sub-agent's transcript.
    private func writeSubagent(_ lines: [String], session: String) throws {
        let dir = root
            .appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func turnLog(from start: Date, to end: Date) async -> TurnCostLog {
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, saveInterval: 0, calendar: calendar)
        await aggregator.refresh()
        return await aggregator.turnCosts(from: start, to: end)
    }

    /// A chat that was compacted between two prompts.
    private var compactedChat: [String] {
        [
            humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            compactSummary(at: minutesAgo(60), session: chatA),
            humanPrompt("Now the changelog", at: minutesAgo(50), session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(45), session: chatA),
        ]
    }

    // MARK: - Tests

    func testACompactionOnTheChatsOwnThreadIsKept() async throws {
        try writeMain(compactedChat, session: chatA)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertEqual(log.compactions, [chatA: [minutesAgo(60)]])
    }

    func testASubAgentsCompactionIsNotItsChats() async throws {
        try writeMain([mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA)], session: chatA)
        try writeSubagent([
            agentTurn(id: "msg_agent", at: minutesAgo(50), session: chatA),
            agentCompaction(at: minutesAgo(40), session: chatA),
        ], session: chatA)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertEqual(log.turns.count, 2)
        XCTAssertNil(log.compactions[chatA], "the agent's context was compacted, not the chat's")
    }

    func testEveryPromptTheUserTypedIsKeptInOrderWithItsTime() async throws {
        try writeMain(compactedChat, session: chatA)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertEqual(log.prompts[chatA], [
            ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test"),
            ChatPrompt(at: minutesAgo(50), text: "Now the changelog"),
        ], "the summary after the compaction is Claude Code's, not the user's")
        XCTAssertEqual(log.titles[chatA], "Fix the flaky reset test", "the first prompt still names the chat")
    }

    func testALineReadTwiceIsKeptOnce() async throws {
        let prompt = humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA)
        let boundary = compaction(at: minutesAgo(60), session: chatA)
        try writeMain([
            prompt, prompt,
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            boundary, boundary,
        ], session: chatA)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertEqual(log.compactions, [chatA: [minutesAgo(60)]])
        XCTAssertEqual(log.prompts[chatA], [ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test")])
    }

    func testOnlyTheChatsAmongTheTurnsComeWithTheirEvents() async throws {
        try writeMain([
            humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
        ], session: chatA)
        try writeMain([
            humanPrompt("Old work", at: minutesAgo(300), session: chatB),
            mainTurn(id: "msg_b1", at: minutesAgo(290), session: chatB),
            compaction(at: minutesAgo(280), session: chatB),
        ], session: chatB)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertEqual(Set(log.prompts.keys), [chatA])
        XCTAssertEqual(log.compactions, [:], "chat B ran outside the range")
    }

    func testEventsOlderThanTheTurnsHorizonAreNotKept() async throws {
        let thirtyTwoDays = 32 * 24 * 60.0
        try writeMain([
            humanPrompt("Last month", at: minutesAgo(thirtyTwoDays), session: chatA),
            compaction(at: minutesAgo(thirtyTwoDays - 10), session: chatA),
            humanPrompt("Today", at: minutesAgo(30), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(20), session: chatA),
        ], session: chatA)
        let log = await turnLog(from: minutesAgo(200), to: now)
        XCTAssertNil(log.compactions[chatA])
        XCTAssertEqual(log.prompts[chatA], [ChatPrompt(at: minutesAgo(30), text: "Today")])
        XCTAssertEqual(log.titles[chatA], "Last month", "the chat is still named by its first prompt")
    }
}
