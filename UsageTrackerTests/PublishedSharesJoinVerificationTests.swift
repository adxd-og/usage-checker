import XCTest
@testable import Omelette

/// The join between what the cost logs hand the share rule (`turnCosts(from:to:)`, chat
/// ids) and what `status.json` lists (`sessions(from:to:)`, chat ids), from log lines in
/// the shapes real logs have: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data. A share that
/// is cut for a chat id the list does not carry is never written, so the two must agree
/// on every chat, sub-agents included. Dates follow the real clock because the
/// aggregators decide "recent" by `Date()`.
final class PublishedSharesJoinVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private let chatA = "5b1c0a52-7a40-4d65-9a38-0e5c1b6f2d11"
    private let chatB = "c3d2e9a7-4b0f-4c1d-8e6a-91f5b7a0d822"
    private let chatC = "0f6a1b2c-3d4e-4f50-8192-a3b4c5d6e7f8"
    private let chatD = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
    private let agentID = "a1b2c3d4e5f607182"
    private let alpha = "-Users-tester-Projects-alpha"

    private let utc: Calendar = {
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
            .appendingPathComponent("PublishedSharesJoinVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            ),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Claude

    private func claudeTurn(id: String, at date: Date, input: Int, session: String, agent: Bool = false) -> String {
        let sidechain = agent ? "true" : "false"
        let agentField = agent ? "\"agentId\":\"\(agentID)\",\"attributionAgent\":\"planner\"," : ""
        return """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":\(sidechain),\(agentField)\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "service_tier":"standard"}},"requestId":"req_\(id)","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session)","version":"2.1.263","gitBranch":"main"}
        """
    }

    private func writeClaude(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(alpha, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func writeClaudeAgent(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(alpha, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func claudeMax() -> ServiceSnapshot {
        // A session window of now - 3 h to now + 2 h, and a week of now - 4 d to now + 3 d:
        // both bin edges fall on a multiple of half an hour from now.
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 10,
                           resetsAt: now.addingTimeInterval(2 * hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 20,
                           resetsAt: now.addingTimeInterval(3 * day), kind: .weekly),
        ], at: now)
    }

    func testClaudeChatsInTheLogCarryTheSharesTheFileListsThemWith() async throws {
        // A $9 and B $3 in the half hour 60 to 30 minutes ago; C $3 ten minutes ago;
        // D $3 two days ago. A sub-agent of C spent $3 in the same half hour as C's turn.
        try writeClaude([claudeTurn(id: "msg_a", at: now.addingTimeInterval(-45 * minute), input: 3_000_000, session: chatA)], session: chatA)
        try writeClaude([claudeTurn(id: "msg_b", at: now.addingTimeInterval(-44 * minute), input: 1_000_000, session: chatB)], session: chatB)
        try writeClaude([claudeTurn(id: "msg_c", at: now.addingTimeInterval(-10 * minute), input: 1_000_000, session: chatC)], session: chatC)
        try writeClaudeAgent([
            claudeTurn(id: "msg_ca", at: now.addingTimeInterval(-9 * minute), input: 1_000_000, session: chatC, agent: true),
        ], session: chatC)
        try writeClaude([claudeTurn(id: "msg_d", at: now.addingTimeInterval(-2 * day), input: 1_000_000, session: chatD)], session: chatD)
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, saveInterval: 0, calendar: utc)
        await aggregator.refresh()

        // The session reached 4 % by 40 minutes ago and 10 % now. The week reached 6 %
        // ten minutes after D's turn and 20 % now.
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: now.addingTimeInterval(-40 * minute), percent: 4),
        ]) + Fixture.readings(bucketID: "seven_day", points: [
            (at: now.addingTimeInterval(-2 * day + 10 * minute), percent: 6),
        ])
        let sources = PublishedShareRules.Sources(
            turns: { await aggregator.turnCosts(from: $0, to: $1) },
            readings: { since in readings.filter { $0.timestamp >= since } }
        )

        let shares = await PublishedShareRules.shares(
            services: [claudeMax()], weeklyBudgetUSD: 0, now: now, calendar: utc, sources: ["claude": sources]
        )
        let sessions = await aggregator.sessions(from: now.addingTimeInterval(-7 * day), to: now)
        let file = StatusFileWriter.build(
            services: [claudeMax()], costs: [:], sessions: ["claude": sessions], shares: shares,
            agents: .none, now: now, calendar: utc, locale: Locale(identifier: "en_GB")
        )
        let entries = Dictionary(
            uniqueKeysWithValues: (file.services.first?.sessions ?? []).map { ($0.id, $0) }
        )

        XCTAssertEqual(Set(entries.keys), [chatA, chatB, chatC, chatD], "the log lists every chat")
        // Session: the 4 points of the first half hour go 9 : 3 to A and B; the last 6
        // go to C and its sub-agent, whose turns share a half hour. C and its sub-agent
        // are one chat.
        XCTAssertEqual(entries[chatA]?.sessionShare, 3)
        XCTAssertEqual(entries[chatB]?.sessionShare, 1)
        XCTAssertEqual(entries[chatC]?.sessionShare, 6)
        XCTAssertNil(entries[chatD]?.sessionShare, "D ran two days ago, outside the session window")
        // Week: D has the first 6 points, C the 14 that came with the last half hour.
        // A and B ran in half hours the week did not move through.
        XCTAssertEqual(entries[chatD]?.weekShare, 6)
        XCTAssertEqual(entries[chatC]?.weekShare, 14)
        XCTAssertEqual(entries[chatA]?.weekShare, 0)
        XCTAssertEqual(entries[chatB]?.weekShare, 0)
    }

    // MARK: - Codex

    private let model = "gpt-5.6-terra"
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let parent = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agent = "01a073d5-72f2-7020-8904-65c6d733aca7"
    private let other = "01a073d6-1111-7020-8904-65c6d733ac00"

    func testCodexChatsAndTheirSubAgentsCarryTheWeekShareUnderTheListedChatId() async throws {
        let tree = try CodexTree(under: root)
        let t = now.addingTimeInterval(-45 * minute)
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: cwd, originator: "codex-tui", at: t.addingTimeInterval(-60)),
            CodexRollout.turnContext(turnID: "turn-p", model: model, effort: "high", cwd: cwd, at: t.addingTimeInterval(-50)),
            CodexRollout.record(at: t.addingTimeInterval(-30 * minute), threadID: parent, sessionID: parent, turnID: "turn-p",
                                responseID: "resp_p0", input: 1_000, cached: 0, output: 0, reasoning: 0),
        ], named: "rollout-2026-09-06T10-00-00-\(parent).jsonl")
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: parent, threadID: agent, parentThreadID: parent,
                                      nickname: "Bacon", agentPath: "/root/review", cwd: cwd, at: t.addingTimeInterval(-60)),
            CodexRollout.turnContext(turnID: "turn-a", model: model, cwd: cwd, at: t.addingTimeInterval(-50)),
            CodexRollout.record(at: t, threadID: agent, sessionID: parent, turnID: "turn-a",
                                responseID: "resp_a", input: 1_000, cached: 0, output: 0, reasoning: 0),
        ], named: "rollout-2026-09-06T11-00-00-\(agent).jsonl")
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: other, threadID: other, cwd: cwd, originator: "codex_exec", at: t.addingTimeInterval(-60)),
            CodexRollout.turnContext(turnID: "turn-o", model: model, cwd: cwd, at: t.addingTimeInterval(-50)),
            CodexRollout.record(at: t.addingTimeInterval(60), threadID: other, sessionID: other, turnID: "turn-o",
                                responseID: "resp_o", input: 1_000, cached: 0, output: 0, reasoning: 0),
        ], named: "rollout-2026-09-06T11-00-00-\(other).jsonl")
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()

        // Prolite: the week alone. 4 points by 40 minutes ago, still 4 now. The
        // sub-agent's turn and the other chat's turn share one half hour, equal dollars.
        let prolite = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [
            Fixture.bucket(id: "codex_session", label: "Weekly", percent: 4,
                           resetsAt: now.addingTimeInterval(day), kind: .weekly,
                           windowLength: 10_080 * 60),
        ], at: now)
        let readings = Fixture.readings(service: "codex", bucketID: "codex_session", points: [
            (at: now.addingTimeInterval(-40 * minute), percent: 4),
        ])
        let sources = PublishedShareRules.Sources(
            turns: { await aggregator.turnCosts(from: $0, to: $1) },
            readings: { since in readings.filter { $0.timestamp >= since } }
        )

        let shares = await PublishedShareRules.shares(
            services: [prolite], weeklyBudgetUSD: 0, now: now, calendar: utc, sources: ["codex": sources]
        )
        let sessions = await aggregator.sessions(from: now.addingTimeInterval(-7 * day), to: now)
        let file = StatusFileWriter.build(
            services: [prolite], costs: [:], sessions: ["codex": sessions], shares: shares,
            agents: .none, now: now, calendar: utc, locale: Locale(identifier: "en_GB")
        )
        let entries = Dictionary(
            uniqueKeysWithValues: (file.services.first?.sessions ?? []).map { ($0.id, $0) }
        )

        XCTAssertEqual(Set(entries.keys), [parent, other], "a sub-agent is its parent's chat, not a chat")
        XCTAssertEqual(entries[parent]?.weekShare, 2, "the parent's own turn moved nothing; its sub-agent shared the half hour")
        XCTAssertEqual(entries[other]?.weekShare, 2)
        XCTAssertNil(entries[parent]?.sessionShare, "Prolite has no session window")
        XCTAssertNil(entries[other]?.sessionShare)
    }
}
