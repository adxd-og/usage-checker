import XCTest
@testable import Omelette

/// Limit analytics' turn query, the Claude half: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Turns, and
/// § Packages 1 (`turnCosts(from:to:)`: time, chat id, project, cost, tokens, and chat
/// titles). The fixture lines are the shapes `~/.claude/projects` holds on this Mac
/// (Claude Code 2.1.263), with ids, names and paths scrubbed:
/// - a main transcript with a provisional and a final record for one message id;
/// - a sub-agent transcript under `<session>/subagents/`;
/// - an `ai-title` record and human prompts.
///
/// Dollars come from the static `ModelPricing` table: Sonnet 4.5 at $3 input and $15
/// output per million tokens, Opus 4.5 at $5 input. Dates are relative to the real
/// clock, because the aggregator decides "recent" by `Date()`.
final class JSONLTurnCostsTests: XCTestCase {
    private var root: URL!
    /// Whole seconds, so a timestamp survives the fixture's format/parse round trip.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private let chatA = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let chatB = "90a2e89b-86f7-438b-bbb1-d0b5735809e3"
    private let chatOld = "4c1f7e2a-9b3d-4e8f-a6c5-2d7b9e0f1a34"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let betaSlug = "-Users-tester-Projects-beta"
    private let agentID = "a06ceeae2762ca204"

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
            .appendingPathComponent("JSONLTurnCostsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: - Fixture records

    /// A main-thread assistant record as Claude Code 2.1.263 writes it, content elided.
    private func mainTurn(
        id: String, at date: Date, model: String = "claude-sonnet-4-5",
        input: Int = 0, output: Int = 0, session: String
    ) -> String {
        """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":false,\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":\(output),\
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

    /// A sub-agent record: `isSidechain`, `agentId`, `attributionAgent`, and the
    /// parent's `sessionId`.
    private func agentTurn(
        id: String, at date: Date, model: String = "claude-opus-4-5", input: Int, session: String
    ) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CeqhfbvWNe5EU6Yax6z9r","attributionAgent":"planner",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.263","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":0,"service_tier":"standard"}}}
        """
    }

    private func titleLine(_ title: String, session: String) -> String {
        """
        {"type":"ai-title","aiTitle":"\(title)","sessionId":"\(session)"}
        """
    }

    /// The user's own prompt: `origin.kind == "human"`.
    private func humanPromptLine(_ text: String, at date: Date, session: String) -> String {
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

    private func writeMain(_ lines: [String], session: String, project: String) throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    /// `<project>/<sessionId>/subagents/agent-<id>.jsonl`, where Claude Code puts a
    /// sub-agent's transcript.
    private func writeSubagent(_ lines: [String], session: String, project: String) throws {
        let dir = root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    /// Chat A in alpha:
    /// - a $3 Sonnet turn 110 minutes ago;
    /// - a turn 60 minutes ago logged twice, first provisional (2 output tokens), then
    ///   final (100,000 output tokens, $1.50);
    /// - a $5 Opus sub-agent turn 50 minutes ago;
    /// - an `ai-title`.
    ///
    /// Chat B in beta: a $3 turn 30 minutes ago, named only by its prompt. A third chat
    /// ran five hours ago, outside every range asked here.
    private func writeChats() throws {
        try writeMain([
            humanPromptLine("Fix the flaky reset test", at: minutesAgo(120), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(110), input: 1_000_000, session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(60), output: 2, session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(60), output: 100_000, session: chatA),
            titleLine("Flaky reset test", session: chatA),
        ], session: chatA, project: alphaSlug)
        try writeSubagent([
            agentTurn(id: "msg_agent", at: minutesAgo(50), input: 1_000_000, session: chatA),
        ], session: chatA, project: alphaSlug)
        try writeMain([
            humanPromptLine("Draft the changelog", at: minutesAgo(31), session: chatB),
            mainTurn(id: "msg_b1", at: minutesAgo(30), input: 1_000_000, session: chatB),
        ], session: chatB, project: betaSlug)
        try writeMain([
            humanPromptLine("Old work", at: minutesAgo(301), session: chatOld),
            mainTurn(id: "msg_old", at: minutesAgo(300), input: 1_000_000, session: chatOld),
        ], session: chatOld, project: alphaSlug)
    }

    private func loaded() async -> JSONLAggregator {
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, saveInterval: 0, calendar: calendar)
        await aggregator.refresh()
        return aggregator
    }

    // MARK: - Tests

    func testEveryTurnInTheRangeComesBackOldestFirstWithItsChatProjectAndPrice() async throws {
        try writeChats()
        let log = await loaded().turnCosts(from: minutesAgo(200), to: now)

        XCTAssertEqual(
            log.turns.map(\.timestamp),
            [minutesAgo(110), minutesAgo(60), minutesAgo(50), minutesAgo(30)],
            "oldest first; the chat from five hours ago is outside the range"
        )
        XCTAssertEqual(log.turns.map(\.chatID), [chatA, chatA, chatA, chatB])
        XCTAssertEqual(log.turns.map(\.projectSlug), [alphaSlug, alphaSlug, alphaSlug, betaSlug])
        XCTAssertEqual(
            log.turns.map(\.model),
            ["claude-sonnet-4-5", "claude-sonnet-4-5", "claude-opus-4-5", "claude-sonnet-4-5"]
        )
        XCTAssertEqual(log.turns[0].tokens.input, 1_000_000)
        XCTAssertEqual(log.turns[0].cost, 3, accuracy: 1e-9)
        XCTAssertEqual(
            log.turns[1].tokens.output, 100_000,
            "the final record's counters, never the provisional one's"
        )
        XCTAssertEqual(log.turns[1].cost, 1.5, accuracy: 1e-9)
        XCTAssertEqual(log.turns[2].cost, 5, accuracy: 1e-9)
        XCTAssertEqual(log.turns[3].cost, 3, accuracy: 1e-9)
        XCTAssertEqual(
            log.turns.map(\.cost), log.turns.map { $0.tokens.cost?.total ?? -1 },
            "a turn's dollars are its priced tokens' dollars"
        )
    }

    func testASubAgentsTurnBelongsToTheChatThatLaunchedIt() async throws {
        try writeChats()
        let log = await loaded().turnCosts(from: minutesAgo(200), to: now)

        let subAgentTurn = try XCTUnwrap(log.turns.first { $0.model == "claude-opus-4-5" })
        XCTAssertEqual(subAgentTurn.chatID, chatA, "the sub-agent transcript carries its parent's sessionId")
        XCTAssertFalse(subAgentTurn.isMainThread)
        XCTAssertEqual(subAgentTurn.projectSlug, alphaSlug, "the project its parent ran in, never `subagents`")
        XCTAssertEqual(log.turns.filter(\.isMainThread).count, 3)
    }

    func testEachChatInTheRangeIsNamedByItsTitleOrItsFirstPrompt() async throws {
        try writeChats()
        let log = await loaded().turnCosts(from: minutesAgo(200), to: now)

        XCTAssertEqual(
            log.titles, [chatA: "Flaky reset test", chatB: "Draft the changelog"],
            "the ai-title wins over the prompt; a chat outside the range is not named"
        )
    }

    func testTheQueryAnswersThroughTheCostLogProtocol() async throws {
        try writeChats()
        let aggregator = await loaded()
        let erased: any CostLogAggregating = aggregator

        let direct = await aggregator.turnCosts(from: minutesAgo(200), to: now)
        let viaProtocol = await erased.turnCosts(from: minutesAgo(200), to: now)

        XCTAssertEqual(
            viaProtocol, direct,
            "DashboardState reaches the log as `any CostLogAggregating`; a method spelled without `async` would answer the empty default here"
        )
        XCTAssertEqual(viaProtocol.turns.count, 4)
    }
}
