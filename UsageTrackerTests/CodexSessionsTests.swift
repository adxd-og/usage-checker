import XCTest
@testable import Omelette

/// Spec § 3's session aggregate and § 1's `sessions(from:to:)` contract, for Codex.
/// The sub-agent fixture is the shape of this Mac's 2026-09-06 02:09 rollout: line 1 is
/// the agent's own `session_meta` (`thread_source: "subagent"`, `session_id` equal to
/// the parent's, its own `id`), and line 2 is a verbatim copy of the parent's meta,
/// which must be ignored.
final class CodexSessionsTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// UTC so a day boundary means the same thing wherever the suite runs, anchored an
    /// hour into the day so `now − 1 day` is never the same UTC day as `now`.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date!

    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let sessionID = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let parentThread = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agentThread = "01a073d5-72f2-7020-8904-65c6d733aca7"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        let real = Date()
        // Truncated to a whole second: a fixture timestamp is written with millisecond
        // precision, so only a whole second survives the format/parse round trip
        // unchanged and lets `firstAt` / `lastAt` be compared for equality.
        now = Date(timeIntervalSince1970:
            max(real, calendar.startOfDay(for: real).addingTimeInterval(3600))
                .timeIntervalSince1970.rounded(.down))
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        return aggregator
    }

    /// The parent thread: one response, 1_000/400/0/100/30.
    private func writeParent() throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: parentThread,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-p", model: model, effort: "high",
                                     cwd: cwd, at: at(3_690)),
            CodexRollout.record(at: at(3_600), threadID: parentThread, sessionID: sessionID,
                                turnID: "turn-p", responseID: "resp_p",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-06T10-00-00-\(parentThread).jsonl")
    }

    /// The sub-agent: its own meta, then a COPY of the parent's, then one response,
    /// 2_000/1_000/0/200/50.
    private func writeAgent(nickname: String? = "Bacon", path: String? = "/root/installer_review") throws {
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: sessionID, threadID: agentThread,
                                      parentThreadID: parentThread, nickname: nickname,
                                      agentPath: path, cwd: cwd, at: at(1_900)),
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: parentThread,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-a", model: model, effort: "low",
                                     cwd: cwd, at: at(1_890)),
            CodexRollout.record(at: at(1_800), threadID: agentThread, sessionID: sessionID,
                                turnID: "turn-a", responseID: "resp_a",
                                input: 2_000, cached: 1_000, output: 200, reasoning: 50),
        ], named: "rollout-2026-09-06T10-30-00-\(agentThread).jsonl")
    }

    private func allSessions(_ aggregator: CodexUsageAggregator) async -> [SessionSummary] {
        await aggregator.sessions(from: at(4 * 24 * 3_600), to: now)
    }

    // MARK: - Identity

    func testAParentAndItsSubAgentAreOneSessionWithOneAgent() async throws {
        try writeParent()
        try writeAgent()

        let sessions = await allSessions(loaded())
        XCTAssertEqual(sessions.count, 1, "the sub-agent's session_id is the parent's")
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.id, sessionID)
        XCTAssertEqual(s.providerID, "codex")
        XCTAssertEqual(s.origin, "codex_exec")
        XCTAssertEqual(s.projectSlug, "%2Ftmp%2FCodex%20Fixtures%2Falpha%20app")
        XCTAssertEqual(s.turns, 2, "the main thread's response and the agent's")
        XCTAssertEqual(s.firstAt, at(3_600))
        XCTAssertEqual(s.lastAt, at(1_800))

        XCTAssertEqual(s.mainTokens.input, 600)
        XCTAssertEqual(s.mainTokens.cacheRead, 400)
        XCTAssertEqual(s.mainTokens.output, 100)
        XCTAssertEqual(s.mainTokens.total, 1_100)
        XCTAssertEqual(s.mainTokens.cost?.total ?? -1, 0.0018, accuracy: 1e-12)

        XCTAssertEqual(s.tokens.input, 1_600, "main 600 + agent 1_000")
        XCTAssertEqual(s.tokens.cacheRead, 1_400)
        XCTAssertEqual(s.tokens.output, 300)
        XCTAssertEqual(s.tokens.thinking, 80)
        XCTAssertEqual(s.tokens.total, 3_300)
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.005175, accuracy: 1e-12)

        XCTAssertEqual(s.agents.count, 1)
        let agent = try XCTUnwrap(s.agents.first)
        XCTAssertEqual(agent.id, agentThread, "the agent's own thread id, not the parent's")
        XCTAssertEqual(agent.kind, "Bacon")
        XCTAssertEqual(agent.model, model)
        XCTAssertEqual(agent.effort, "low")
        XCTAssertEqual(agent.turns, 1)
        XCTAssertEqual(agent.tokens.total, 2_200)
        XCTAssertEqual(agent.firstAt, at(1_800))
        XCTAssertEqual(agent.lastAt, at(1_800))
    }

    func testTheCopiedParentMetaOnLineTwoIsIgnored() async throws {
        // If the second `session_meta` were adopted, the agent's file would call itself
        // the main thread and its 2_200 tokens would land in `mainTokens`.
        try writeParent()
        try writeAgent()

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.mainTokens.total, 1_100, "only the parent thread's response")
        XCTAssertEqual(s.agents.count, 1)
    }

    func testAnAgentWithNoNicknameFallsBackToItsPath() async throws {
        try writeParent()
        try writeAgent(nickname: nil, path: "/root/installer_review")

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.agents.first?.kind, "/root/installer_review")
    }

    func testAnAgentWithNeitherNicknameNorPathIsStillAnAgent() async throws {
        try writeParent()
        try writeAgent(nickname: nil, path: nil)

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.agents.count, 1)
        XCTAssertEqual(s.agents.first?.kind, "sub-agent")
    }

    func testASessionWithNoSubAgentsReportsNoneAndAllItsTokensAsMain() async throws {
        try writeParent()

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)
        XCTAssertTrue(s.agents.isEmpty)
        XCTAssertEqual(s.mainTokens, s.tokens)
        XCTAssertEqual(s.turns, 1)
    }

    func testARolloutWithNoSessionMetaFallsBackToItsThreadIDForIdentity() async throws {
        // The parser can start mid-file. The thread uuid in the name is then the only
        // identity there is — and it is the same one the meta would have given.
        let orphan = "01a075fd-c1dd-7b11-90d5-ad4bff47b670"
        try tree.writeRollout([
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(900)),
            CodexRollout.record(at: at(600), threadID: orphan, responseID: "resp_o",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-06T12-12-39-\(orphan).jsonl")

        let sessions = await allSessions(loaded())
        XCTAssertEqual(sessions.map(\.id), [orphan])
        XCTAssertNil(sessions.first?.origin)
    }

    func testTwoSessionsComeBackNewestFirst() async throws {
        try writeParent()
        let other = "01a061ac-98a5-7933-b626-c67610327f53"
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: other, cwd: "/tmp/Codex Fixtures/beta",
                                     originator: "codex-tui", at: at(400)),
            CodexRollout.turnContext(model: model, cwd: "/tmp/Codex Fixtures/beta", at: at(390)),
            CodexRollout.record(at: at(300), threadID: other, responseID: "resp_x",
                                input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-2026-09-06T13-00-00-\(other).jsonl")

        let sessions = await allSessions(loaded())
        XCTAssertEqual(sessions.map(\.id), [other, sessionID], "ordered by lastAt, newest first")
        XCTAssertEqual(sessions.first?.origin, "codex-tui")
    }

    // MARK: - The pure summary rule

    func testTheSummaryRuleReSumsTheClippedDaysAndKeepsTheSessionSpan() throws {
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_788_700_000))
        let day1 = calendar.date(byAdding: .day, value: 1, to: day0)!
        let day2 = calendar.date(byAdding: .day, value: 2, to: day0)!
        let one = TokenBreakdown(input: 100, output: 10)
        let two = TokenBreakdown(input: 200, output: 20)
        let three = TokenBreakdown(input: 300, output: 30)

        let agg = CodexUsageAggregator.SessionAgg(
            projectSlug: "slug",
            origin: "codex_exec",
            firstAt: day0.addingTimeInterval(3_600),
            lastAt: day2.addingTimeInterval(3_600),
            turns: 3,
            tokens: one + two + three,
            mainTokens: one + two + three,
            byDay: [
                day0: .init(turns: 1, tokens: one, mainTokens: one),
                day1: .init(turns: 1, tokens: two, mainTokens: two),
                day2: .init(turns: 1, tokens: three, mainTokens: .zero),
            ],
            agents: [
                "agent-old": .init(kind: "Old", model: "m", effort: "low",
                                   firstAt: day0.addingTimeInterval(60),
                                   lastAt: day0.addingTimeInterval(120),
                                   turns: 1, tokens: one),
                "agent-new": .init(kind: "New", model: "m", effort: "high",
                                   firstAt: day2.addingTimeInterval(60),
                                   lastAt: day2.addingTimeInterval(120),
                                   turns: 1, tokens: three),
            ],
            hasMainIdentity: true
        )

        let s = try XCTUnwrap(CodexUsageAggregator.summary(
            sessionID: "s", agg: agg, title: "Title",
            from: day1.addingTimeInterval(5_000), to: day2.addingTimeInterval(5_000),
            calendar: calendar
        ))
        XCTAssertEqual(s.days.map(\.day), [day1, day2], "ascending, and only the days in range")
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.tokens, two + three)
        XCTAssertEqual(s.mainTokens, two, "day 2's tokens were all an agent's")
        XCTAssertEqual(s.firstAt, day0.addingTimeInterval(3_600), "the session's own span, unclipped")
        XCTAssertEqual(s.lastAt, day2.addingTimeInterval(3_600))
        XCTAssertEqual(s.title, "Title")
        XCTAssertEqual(s.agents.map(\.id), ["agent-new"], "the agent that ran before the range is dropped")
    }

    func testTheSummaryRuleDropsASessionWithNoDayInRange() {
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_788_700_000))
        let later = calendar.date(byAdding: .day, value: 5, to: day0)!
        let agg = CodexUsageAggregator.SessionAgg(
            projectSlug: "slug", origin: nil,
            firstAt: day0, lastAt: day0, turns: 1,
            tokens: TokenBreakdown(input: 1), mainTokens: TokenBreakdown(input: 1),
            byDay: [day0: .init(turns: 1, tokens: TokenBreakdown(input: 1),
                                mainTokens: TokenBreakdown(input: 1))],
            agents: [:], hasMainIdentity: true
        )
        XCTAssertNil(CodexUsageAggregator.summary(
            sessionID: "s", agg: agg, title: nil,
            from: later, to: calendar.date(byAdding: .day, value: 6, to: day0)!,
            calendar: calendar
        ))
    }

    func testAgentsAreOrderedByCostThenID() {
        let day0 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_788_700_000))
        let cheap = TokenBreakdown(input: 100).priced(
            with: ModelPrice(inputPerM: 1, outputPerM: 1, cacheReadPerM: 0,
                             cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
        )
        let dear = TokenBreakdown(input: 900).priced(
            with: ModelPrice(inputPerM: 1, outputPerM: 1, cacheReadPerM: 0,
                             cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
        )
        func agent(_ kind: String, _ tokens: TokenBreakdown) -> CodexUsageAggregator.AgentAgg {
            .init(kind: kind, model: nil, effort: nil, firstAt: day0, lastAt: day0,
                  turns: 1, tokens: tokens)
        }
        let agg = CodexUsageAggregator.SessionAgg(
            projectSlug: "slug", origin: nil, firstAt: day0, lastAt: day0, turns: 3,
            tokens: cheap + cheap + dear, mainTokens: .zero,
            byDay: [day0: .init(turns: 3, tokens: cheap + cheap + dear, mainTokens: .zero)],
            agents: ["b": agent("B", cheap), "a": agent("A", cheap), "c": agent("C", dear)],
            hasMainIdentity: true
        )
        let s = CodexUsageAggregator.summary(
            sessionID: "s", agg: agg, title: nil, from: day0, to: day0, calendar: calendar
        )
        XCTAssertEqual(s?.agents.map(\.id), ["c", "a", "b"])
    }
}
