import XCTest
@testable import Omelette

/// Independent verification of `CodexUsageAggregator`'s per-model split, against the
/// spec rather than the executor's own `CodexSessionsTests` fixtures:
/// docs/superpowers/specs/2026-09-10-sessions-by-model-design.md § Design (Codex),
/// ruling 8 ("Codex attributes a `token_usage_record` to a `turn_context` by
/// `turn_id`") and ruling 9 (model rows are never clipped by a range).
///
/// Fixtures reuse the shared `CodexRollout` / `CodexTree` builders (the same ones
/// `CodexSessionsTests` uses), which is the project's fixture layer, not the
/// executor's test file; no test or assertion here is copied from it.
final class SessionsByModelCodexVerificationTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date!
    private let cwd = "/tmp/Codex Fixtures/verify app"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionsByModelCodexVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        let real = Date()
        now = Date(timeIntervalSince1970:
            max(real, calendar.startOfDay(for: real).addingTimeInterval(3_600))
                .timeIntervalSince1970.rounded(.down))
        ModelPricing.updateDynamic([
            "gpt-8": ModelPrice(
                inputPerM: 4, outputPerM: 20, cacheReadPerM: 0.4,
                cacheCreate5mPerM: 5, cacheCreate1hPerM: 8
            ),
            // A distinct rate from "gpt-8" so a per-model row can be told apart by its
            // dollars, the way the executor's own two-model fixture is priced apart.
            "gpt-9": ModelPrice(
                inputPerM: 1, outputPerM: 6, cacheReadPerM: 0.1,
                cacheCreate5mPerM: 1.25, cacheCreate1hPerM: 2
            ),
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

    private func allSessions(_ aggregator: CodexUsageAggregator) async -> [SessionSummary] {
        await aggregator.sessions(from: at(10 * 24 * 3_600), to: now)
    }

    // MARK: - Two token_usage_records under two turn_contexts: each its own row

    func testTwoRecordsUnderTwoDifferentTurnContextsLandOnTwoDifferentModelRows() async throws {
        let sessionID = "verify-two-models-0001"
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: sessionID,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-x", model: "gpt-8-nova", effort: "medium",
                                     cwd: cwd, at: at(3_690)),
            CodexRollout.record(at: at(3_600), threadID: sessionID, sessionID: sessionID,
                                turnID: "turn-x", responseID: "resp-x",
                                input: 1_000, cached: 0, output: 100, reasoning: 0),
            CodexRollout.turnContext(turnID: "turn-y", model: "gpt-9-comet", effort: "high",
                                     cwd: cwd, at: at(3_500)),
            CodexRollout.record(at: at(3_400), threadID: sessionID, sessionID: sessionID,
                                turnID: "turn-y", responseID: "resp-y",
                                input: 2_000, cached: 500, output: 50, reasoning: 10),
        ], named: "rollout-verify-two-models.jsonl")

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)

        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(
            Set(s.models.map(\.id)), ["gpt-8-nova|medium", "gpt-9-comet|high"],
            "each record is billed to the turn_context that named its own turn_id"
        )
        let x = try XCTUnwrap(s.models.first { $0.id == "gpt-8-nova|medium" })
        let y = try XCTUnwrap(s.models.first { $0.id == "gpt-9-comet|high" })
        XCTAssertEqual(x.turns, 1)
        XCTAssertEqual(x.tokens.input, 1_000)
        XCTAssertEqual(x.tokens.output, 100)
        XCTAssertEqual(y.turns, 1)
        XCTAssertEqual(y.tokens.input, 1_500, "2_000 raw minus the 500 already cached")
        XCTAssertEqual(y.tokens.cacheRead, 500)
        XCTAssertEqual(y.tokens.output, 50)

        XCTAssertEqual(s.models.reduce(0) { $0 + $1.turns }, s.turns)
        XCTAssertEqual(s.models.reduce(TokenBreakdown.zero) { $0 + $1.tokens }.total, s.tokens.total)
    }

    // MARK: - A record whose turn_id was never opened falls back to the latest context

    func testARecordNamingATurnIdWithNoContextIsBilledToTheLatestContextNotTheFirst() async throws {
        // turn-ghost's own turn_context is never written — the join must fall back to
        // "the latest turn_context the file has seen" (turn-y's), not to turn-x's,
        // which is the exact-match case the executor's own fixture already covers.
        let sessionID = "verify-fallback-0002"
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: sessionID,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-x", model: "gpt-8-nova", effort: "medium",
                                     cwd: cwd, at: at(3_690)),
            CodexRollout.record(at: at(3_650), threadID: sessionID, sessionID: sessionID,
                                turnID: "turn-x", responseID: "resp-x",
                                input: 500, cached: 0, output: 20, reasoning: 0),
            CodexRollout.turnContext(turnID: "turn-y", model: "gpt-9-comet", effort: "high",
                                     cwd: cwd, at: at(3_500)),
            CodexRollout.record(at: at(3_400), threadID: sessionID, sessionID: sessionID,
                                turnID: "turn-ghost", responseID: "resp-ghost",
                                input: 300, cached: 0, output: 10, reasoning: 0),
        ], named: "rollout-verify-fallback.jsonl")

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)

        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(
            Set(s.models.map(\.id)), ["gpt-8-nova|medium", "gpt-9-comet|high"],
            "the ghost record must not be dropped, and must not start a third row"
        )
        let ghostRow = try XCTUnwrap(s.models.first { $0.id == "gpt-9-comet|high" })
        XCTAssertEqual(
            ghostRow.tokens.input, 300,
            "turn-ghost's tokens followed the LATEST turn_context (turn-y), not turn-x's"
        )
        let firstRow = try XCTUnwrap(s.models.first { $0.id == "gpt-8-nova|medium" })
        XCTAssertEqual(firstRow.tokens.input, 500, "turn-x's own record is unaffected by the fallback")
    }

    // MARK: - A sub-agent's response is one of the chat's model rows, sums included

    func testASubAgentsResponseIsOneOfTheChatsModelRowsAndTheSumsAreExact() async throws {
        let sessionID = "verify-subagent-0003"
        let parentThread = sessionID
        let agentThread = "verify-subagent-0003-agent"
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: parentThread,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-p", model: "gpt-8-nova", effort: "medium",
                                     cwd: cwd, at: at(3_690)),
            CodexRollout.record(at: at(3_600), threadID: parentThread, sessionID: sessionID,
                                turnID: "turn-p", responseID: "resp-p",
                                input: 1_000, cached: 200, output: 50, reasoning: 5),
        ], named: "rollout-verify-subagent-parent.jsonl")
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: sessionID, threadID: agentThread,
                                      parentThreadID: parentThread, nickname: "Reviewer",
                                      agentPath: nil, cwd: cwd, at: at(1_900)),
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: parentThread,
                                     cwd: cwd, originator: "codex_exec", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-a", model: "gpt-9-comet", effort: "high",
                                     cwd: cwd, at: at(1_890)),
            CodexRollout.record(at: at(1_800), threadID: agentThread, sessionID: sessionID,
                                turnID: "turn-a", responseID: "resp-a",
                                input: 2_000, cached: 0, output: 80, reasoning: 15),
        ], named: "rollout-verify-subagent-agent.jsonl")

        let sessions = await allSessions(loaded())
        let s = try XCTUnwrap(sessions.first)

        XCTAssertEqual(s.turns, 2, "the main thread's response and the agent's")
        XCTAssertEqual(
            Set(s.models.map(\.id)), ["gpt-8-nova|medium", "gpt-9-comet|high"],
            "the sub-agent's model is one of the chat's own rows"
        )
        XCTAssertEqual(s.models.reduce(0) { $0 + $1.turns }, s.turns)

        let summed = s.models.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        XCTAssertEqual(summed.input, s.tokens.input)
        XCTAssertEqual(summed.output, s.tokens.output)
        XCTAssertEqual(summed.cacheRead, s.tokens.cacheRead)
        XCTAssertEqual(summed.thinking, s.tokens.thinking)
        XCTAssertEqual(
            try XCTUnwrap(summed.cost).total, try XCTUnwrap(s.tokens.cost).total, accuracy: 1e-12
        )
    }

    // MARK: - A clipped range still reports the whole chat's model rows

    func testARangeCoveringOnlyTheNewerOfTwoDaysStillReportsBothModelRows() async throws {
        let sessionID = "verify-clipped-0004"
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let turnToday = min(now.addingTimeInterval(-60), today.addingTimeInterval(3_600 * 2))
        let turnYesterday = yesterday.addingTimeInterval(3_600 * 2)

        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: "\(sessionID)-y",
                                     cwd: cwd, originator: "codex_exec", at: turnYesterday),
            CodexRollout.turnContext(turnID: "turn-yesterday", model: "gpt-8-nova", effort: "medium",
                                     cwd: cwd, at: turnYesterday.addingTimeInterval(-10)),
            CodexRollout.record(at: turnYesterday, threadID: "\(sessionID)-y", sessionID: sessionID,
                                turnID: "turn-yesterday", responseID: "resp-yesterday",
                                input: 400, cached: 0, output: 40, reasoning: 0),
        ], named: "rollout-verify-clipped-yesterday.jsonl")
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, threadID: "\(sessionID)-t",
                                     cwd: cwd, originator: "codex_exec", at: turnToday),
            CodexRollout.turnContext(turnID: "turn-today", model: "gpt-9-comet", effort: "high",
                                     cwd: cwd, at: turnToday.addingTimeInterval(-10)),
            CodexRollout.record(at: turnToday, threadID: "\(sessionID)-t", sessionID: sessionID,
                                turnID: "turn-today", responseID: "resp-today",
                                input: 600, cached: 0, output: 60, reasoning: 0),
        ], named: "rollout-verify-clipped-today.jsonl")

        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        let clippedSessions = await aggregator.sessions(from: today, to: now)
        let clipped = try XCTUnwrap(
            clippedSessions.first,
            "today's turn keeps the chat inside the clipped range"
        )

        XCTAssertEqual(clipped.days.map(\.day), [today], "only today's day survives the clip")
        XCTAssertEqual(clipped.turns, 1, "and only today's one turn")
        XCTAssertEqual(
            Set(clipped.models.map(\.id)), ["gpt-8-nova|medium", "gpt-9-comet|high"],
            "yesterday's model row is kept even though yesterday itself was clipped out"
        )
        XCTAssertEqual(
            clipped.models.reduce(0) { $0 + $1.turns }, 2,
            "the model rows outnumber the clipped chat's own turn count"
        )
    }
}
