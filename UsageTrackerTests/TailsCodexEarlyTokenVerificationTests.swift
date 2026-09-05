import XCTest
@testable import Omelette

/// Independent verification of commit cb6d7c8 (a `token_count` ahead of the file's
/// first `turn_context` is held and billed to the model that follows), written from
/// scratch against `CodexUsageAggregator.swift` rather than by reading the executor's
/// own `CodexEarlyTokenCountTests` / `CodexUsageAggregatorVerificationTests`. Fixture
/// shape is copied from those files' conventions (real rollout field names), not their
/// assertions.
final class TailsCodexEarlyTokenVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaCwd = "/tmp/Tails Fixtures/alpha app"
    private let betaCwd = "/tmp/Tails Fixtures/beta"
    private let alphaName = "Tails Fixtures / alpha app"
    private let priced = "gpt-5.6-terra"
    private let unpriced = "no-such-model-tails"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailsCodexEarlyTokenVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 0, cacheCreate1hPerM: 0
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Fixture writing

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func stamp(_ secondsAgo: Double) -> String {
        iso.string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func sessionMeta(cwd: String, secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"s","id":"s","timestamp":"\(stamp(secondsAgo))","cwd":"\(cwd)",\
        "originator":"codex_exec","cli_version":"0.153.0","source":"exec",\
        "thread_source":"user","model_provider":"openai","history_mode":"default"}}
        """
    }

    private func turnContext(model: String, cwd: String? = nil, secondsAgo: Double) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\",\"workspace_roots\":[\"\($0)\"]," } ?? ""
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"t",\(cwdField)"current_date":"2026-09-05","timezone":"UTC",\
        "approval_policy":"never","model":"\(model)","personality":"default"}}
        """
    }

    private func tokenCount(
        secondsAgo: Double, input: Int, cached: Int, cacheWrite: Int = 0, output: Int, reasoning: Int
    ) -> String {
        let counters = "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)," +
            "\"reasoning_output_tokens\":\(reasoning),\"total_tokens\":\(input + output)"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":18,"type":"event_msg","payload":\
        {"type":"token_count","info":{"total_token_usage":{\(counters)},\
        "last_token_usage":{\(counters)},"model_context_window":258400},\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":1.0,\
        "window_minutes":43200,"resets_at":1790937107}}}}
        """
    }

    /// A `token_count` event whose `info` is JSON `null` — real rollouts write these.
    private func nullInfoTokenCount(secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":16,"type":"event_msg","payload":\
        {"type":"token_count","info":null,"rate_limits":null}}
        """
    }

    private func write(_ lines: [String], day: String = "2026/09/05", named name: String = "rollout-a.jsonl") throws -> URL {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = CodexUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - Pricing and cost

    func testThePendingTurnIsPricedWithTheModelThatFollows() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 690),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        let cost = try XCTUnwrap(usage.breakdown.cost)
        XCTAssertEqual(usage.cost, cost.total, accuracy: 1e-12, "the turn's cost must equal its own breakdown total")
        // 800 fresh input @ $1.25/M + 200 cache read @ $0.125/M + 50 output @ $10/M.
        XCTAssertEqual(usage.cost, 0.001525, accuracy: 1e-12)
    }

    // MARK: - Project identity

    func testTheRecoveredTurnsProjectSlugComesFromSessionMetaCwd() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            // turn_context deliberately carries no cwd of its own — the recovered turn
            // must still land under the session_meta project, not a fallback.
            turnContext(model: priced, cwd: nil, secondsAgo: 690),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.projects.map(\.displayName), [alphaName])
    }

    // MARK: - Isolation across files

    func testOnlyOneOfTwoFilesHasAnEarlyCount() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 690),
        ], named: "rollout-early.jsonl")
        try write([
            sessionMeta(cwd: betaCwd, secondsAgo: 900),
            turnContext(model: priced, cwd: betaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-normal.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "one recovered turn from the early file, one ordinary turn from the other")
        XCTAssertEqual(usage.tokens, 1_050 + 550)
    }

    // MARK: - info:null must not be pended

    func testAnEarlyNullInfoTokenCountIsIgnoredNotPended() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            nullInfoTokenCount(secondsAgo: 800),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 690),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 0, "a null-info event must not have been pended and later recovered as a phantom turn")
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertEqual(usage.cost, 0)
    }

    // MARK: - Recovered turn under an unpriced model

    func testAnEarlyCountFollowedByAnUnpricedModelIsKeptAtZeroCost() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: unpriced, cwd: alphaCwd, secondsAgo: 690),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "an unpriceable recovered turn is still activity")
        XCTAssertEqual(usage.tokens, 1_050)
        XCTAssertEqual(usage.cost, 0, accuracy: 1e-12)
        XCTAssertNil(usage.breakdown.cost, "no rates, so no per-category dollars to invent")
    }

    // MARK: - Incremental parse: pending state survives across polls

    func testPendingStateSurvivesAcrossTwoRefreshesWithNoDoubleCount() async throws {
        let url = try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
        ])
        let aggregator = await loaded()

        // First refresh: only the early count is on disk. No model yet, so nothing is
        // billed — but it must not be dropped either.
        var usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 0)

        // Append turn_context + a second token_count, then refresh again.
        try (
            [
                sessionMeta(cwd: alphaCwd, secondsAgo: 900),
                tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
                turnContext(model: priced, cwd: alphaCwd, secondsAgo: 650),
                tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
            ].joined(separator: "\n") + "\n"
        ).write(to: url, atomically: true, encoding: .utf8)
        await aggregator.refresh()

        usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 2, "exactly two turns: the recovered one plus the new delta, no double count")
        // 800 recovered fresh + max(0, 500 - 100) = 1200; matches the executor's own math
        // for the equivalent single-refresh case, confirming the incremental path agrees.
        XCTAssertEqual(usage.breakdown.input, 1_200)
        XCTAssertEqual(usage.breakdown.cacheRead, 300)
        XCTAssertEqual(usage.breakdown.output, 80)
        XCTAssertEqual(usage.tokens, 1_200 + 80 + 300)
    }

    // MARK: - Negative-delta reset while pending

    /// Two early `token_count` events, no `turn_context` between them, and the second
    /// one's cumulative reading is *lower* than the first — the counter restarted
    /// (compaction / fresh thread) while the tokens were still waiting to be attributed.
    /// The reset must still be treated as a delta-equals-reading event and folded into
    /// the pending sum, not lost and not turned negative.
    func testANegativeDeltaResetWhilePendingIsFoldedNotLost() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            // First reading: cumulative 1000/200/50/10 -> delta = reading (baseline was zero).
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            // Second reading is smaller than the first: input drops 1000 -> 300, output
            // drops 50 -> 20. Negative delta -> the reading itself becomes the "delta".
            tokenCount(secondsAgo: 650, input: 300, cached: 50, output: 20, reasoning: 5),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 640),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "both pending readings recover as one turn")
        // First: fresh 800, cacheRead 200, output 50, reasoning 10.
        // Second (reset, reading==delta): fresh max(0, 300-50)=250, cacheRead 50, output 20, reasoning 5.
        XCTAssertEqual(usage.breakdown.input, 800 + 250)
        XCTAssertEqual(usage.breakdown.cacheRead, 200 + 50)
        XCTAssertEqual(usage.breakdown.output, 50 + 20)
        XCTAssertEqual(usage.breakdown.thinking, 10 + 5)
        XCTAssertGreaterThanOrEqual(usage.breakdown.input, 0, "a reset must never manifest as negative tokens")
    }

    // MARK: - breakdown() / usage(from:to:) see the recovered turn

    func testBreakdownTodayTurnsSeesTheRecoveredTurn() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 60),
            tokenCount(secondsAgo: 50, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 40),
        ], named: "rollout-today.jsonl")

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.todayTurns, 1)
        XCTAssertEqual(breakdown.todayTokens, 1_050)
        XCTAssertGreaterThan(breakdown.todayCost, 0)
    }

    func testUsageFromToSeesTheRecoveredTurn() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 690),
        ])

        let aggregator = await loaded()
        let usage = await aggregator.usage(
            from: now.addingTimeInterval(-3600), to: now
        )
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_050)
    }

    // MARK: - Timestamp: earliest pending event, not turn_context's

    func testTheRecoveredTurnsTimestampIsTheEarliestPendingEventNotTheTurnContexts() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            // Two early events; the *first* one's timestamp (800s ago) must win, not the
            // second's (750s ago) and not turn_context's (700s ago).
            tokenCount(secondsAgo: 800, input: 1_000, cached: 200, output: 50, reasoning: 10),
            tokenCount(secondsAgo: 750, input: 1_500, cached: 300, output: 80, reasoning: 20),
            turnContext(model: priced, cwd: alphaCwd, secondsAgo: 700),
        ])

        let aggregator = await loaded()

        // A window that ends before turn_context's own timestamp (700s ago) but after the
        // earliest pending event (800s ago) must still contain the recovered turn.
        let windowEndingBeforeTurnContext = await aggregator.usage(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(-750)
        )
        XCTAssertEqual(windowEndingBeforeTurnContext.turns, 1, "the recovered turn is stamped at the earliest pending event, not at turn_context")

        // A window ending before even the earliest pending event must not contain it.
        let windowEndingBeforeEverything = await aggregator.usage(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(-850)
        )
        XCTAssertEqual(windowEndingBeforeEverything.turns, 0)
    }

    // MARK: - No turn_context anywhere

    func testAFileWithNoTurnContextRecordsNothing() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 0)
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertTrue(usage.isEmpty)
    }
}
