import XCTest
@testable import Omelette

/// Independent verification of `CodexUsageAggregator` against
/// `docs/superpowers/specs/2026-09-05-token-breakdown-design.md`. These tests were
/// written without reading `CodexUsageAggregatorTests.swift`'s assertions (only its
/// fixture-writing conventions, to stay field-compatible with real rollouts), and
/// deliberately probe different numbers and edge cases: cache-exceeds-input clamping,
/// an absent `cache_write_input_tokens` key, a partial negative delta, a `token_count`
/// preceding any `turn_context`, a model change mid-file, exact week/month boundary
/// ticks, local-midnight day bucketing, project merges across files, and a truncated
/// file being re-read from scratch.
///
/// Every field name mirrors a real rollout
/// (`~/.codex/sessions/2026/09/05/rollout-2026-09-05T22-50-41-01a0731f-….jsonl`, Codex
/// CLI 0.153.4, read 2026-09-05): `session_meta.payload.cwd`, `turn_context.payload.model`,
/// `event_msg`/`token_count`/`info.total_token_usage.{input_tokens,cached_input_tokens,
/// cache_write_input_tokens,output_tokens,reasoning_output_tokens}`, plus the
/// `token_usage_record` duplicate line and (seen on other rollouts on this machine, e.g.
/// `2026/09/03/rollout-…-01a066eb-….jsonl`) a `token_count` with `"info":null`.
final class CodexUsageAggregatorVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaCwd = "/tmp/Codex Verify/alpha app"
    private let betaCwd = "/tmp/Codex Verify/beta"
    private let alphaName = "Codex Verify / alpha app"
    private let betaName = "Codex Verify / beta"

    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageAggregatorVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The exact `Date` the aggregator will parse back out of `stamp(secondsAgo)` — the
    /// same formatter, so a boundary query built from this is bit-identical to the
    /// `Turn.timestamp` it's compared against, with no ISO-fractional-second rounding
    /// hazard.
    private func exactInstant(_ secondsAgo: Double) -> Date {
        iso.date(from: stamp(secondsAgo))!
    }

    private func sessionMeta(cwd: String, secondsAgo: Double) -> String {
        let id = "01a07092-9e5d-7470-b491-400968478d33"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(id)","id":"\(id)","timestamp":"\(stamp(secondsAgo))",\
        "cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.153.4","source":"exec",\
        "thread_source":"user","model_provider":"openai","history_mode":"default"}}
        """
    }

    private func turnContext(model: String, cwd: String?, secondsAgo: Double) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\",\"workspace_roots\":[\"\($0)\"]," } ?? ""
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"01a07092-9ea2-7c40-8c17-f322bdc84723",\(cwdField)\
        "current_date":"2026-09-05","timezone":"Europe/Vilnius","approval_policy":"never",\
        "model":"\(model)","personality":"default"}}
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
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":72.0,\
        "window_minutes":43200,"resets_at":1790937107}}}}
        """
    }

    /// `cache_write_input_tokens` entirely absent (not merely 0) — a real rollout has
    /// never shown this, but the spec's "0 when the key is absent" is about the JSON
    /// shape, not just the value.
    private func tokenCountNoCacheWriteKey(secondsAgo: Double, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        let counters = "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"output_tokens\":\(output),\"reasoning_output_tokens\":\(reasoning)," +
            "\"total_tokens\":\(input + output)"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":18,"type":"event_msg","payload":\
        {"type":"token_count","info":{"total_token_usage":{\(counters)},"model_context_window":258400},\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":72.0,\
        "window_minutes":43200,"resets_at":1790937107}}}}
        """
    }

    private func tokenUsageRecord(secondsAgo: Double, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":15,"type":"token_usage_record","payload":\
        {"thread_id":"t","turn_id":"u","usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),\
        "total_tokens":\(input + output)}}}
        """
    }

    private func nullInfoTokenCount(secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":16,"type":"event_msg","payload":\
        {"type":"token_count","info":null,"rate_limits":null}}
        """
    }

    @discardableResult
    private func write(
        _ lines: [String], day: String = "2026/09/05", named name: String = "rollout-a.jsonl"
    ) throws -> URL {
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

    // MARK: - A. Delta arithmetic

    func testThreeDeltasSumToTheirBucketsAndTheirDollarsMatchTheTurnCost() async throws {
        // Independent numbers from the plan's canonical fixture, exercising the same
        // arithmetic through a different path.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 2_000, cached: 500, output: 300, reasoning: 50),
            tokenCount(secondsAgo: 400, input: 5_000, cached: 1_800, cacheWrite: 100, output: 700, reasoning: 120),
            tokenCount(secondsAgo: 200, input: 9_000, cached: 2_600, cacheWrite: 250, output: 1_000, reasoning: 200),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 3)
        let b = usage.breakdown
        XCTAssertEqual(b.input, 6_400)
        XCTAssertEqual(b.output, 1_000)
        XCTAssertEqual(b.cacheRead, 2_600)
        XCTAssertEqual(b.cacheWrite5m, 250)
        XCTAssertEqual(b.cacheWrite1h, 0)
        XCTAssertEqual(b.thinking, 200)
        XCTAssertEqual(b.total, 10_250)
        XCTAssertEqual(usage.tokens, 10_250)

        let cost = try XCTUnwrap(b.cost)
        XCTAssertEqual(cost.input, 0.008, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 0.01, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 0.000325, accuracy: 1e-9)
        XCTAssertEqual(cost.total, 0.018325, accuracy: 1e-9)
        // The turn dollars (summed independently as `usage.cost`) and the breakdown's
        // own dollars are the same number.
        XCTAssertEqual(usage.cost, cost.total, accuracy: 1e-9)
        XCTAssertEqual(usage.cost, 0.018325, accuracy: 1e-9)
    }

    func testFreshInputClampsAtZeroWhenCacheReadExceedsRawInput() async throws {
        // A reading where the cached counter is larger than the raw input counter —
        // input − cached must clamp at 0, not go negative.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 800, output: 60, reasoning: 5),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.input, 0, "input − cached would be negative; must clamp to 0")
        XCTAssertEqual(usage.breakdown.cacheRead, 800)
        XCTAssertEqual(usage.breakdown.output, 60)
        XCTAssertEqual(usage.breakdown.thinking, 5)
        XCTAssertEqual(usage.tokens, 0 + 60 + 800)
    }

    func testCacheWriteIsZeroWhenTheKeyIsEntirelyAbsentFromJSON() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCountNoCacheWriteKey(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.cacheWrite5m, 0)
        XCTAssertEqual(usage.breakdown.input, 600)
        XCTAssertEqual(usage.breakdown.cacheRead, 400)
    }

    func testThinkingIsASubsetOfOutputAndNeverJoinsTheTotal() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 0, output: 200, reasoning: 150),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.breakdown.thinking, 150)
        XCTAssertEqual(usage.breakdown.output, 200)
        XCTAssertEqual(usage.breakdown.total, 1_000 + 200, "thinking must not be added on top of output")
        XCTAssertEqual(usage.tokens, 1_200)
    }

    func testAPartialNegativeDeltaStillReplacesTheWholeDeltaWithTheReading() async throws {
        // The second reading's input counter goes DOWN (compaction) while output goes
        // up. A correct implementation discards the whole computed delta and uses the
        // reading itself verbatim — including for output, which was not negative.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 5_000, cached: 1_000, output: 500, reasoning: 50),
            tokenCount(secondsAgo: 400, input: 3_000, cached: 1_000, output: 600, reasoning: 60),
        ])

        let aggregator = await loaded()
        let secondTurn = await aggregator.usage(from: now.addingTimeInterval(-500), to: now.addingTimeInterval(-300))
        XCTAssertEqual(secondTurn.turns, 1)
        // If only the negative field were reset, output would show as the naive delta
        // 100 (600 − 500). The reading-as-delta rule says it must be 600 (the reading).
        XCTAssertEqual(secondTurn.breakdown.output, 600, "a negative delta resets the WHOLE reading, not just the negative field")
        XCTAssertEqual(secondTurn.breakdown.cacheRead, 1_000)
        XCTAssertEqual(secondTurn.breakdown.input, 2_000, "max(0, 3000 − 1000)")
        XCTAssertEqual(secondTurn.breakdown.thinking, 60)
    }

    func testARepeatedIdenticalReadingRecordsNoTurn() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 800, cached: 100, output: 40, reasoning: 5),
            tokenCount(secondsAgo: 500, input: 800, cached: 100, output: 40, reasoning: 5),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 800 - 100 + 40 + 100)
    }

    func testATokenCountBeforeAnyTurnContextIsRecoveredWithoutCorruptingTheBaseline() async throws {
        // Deliberately out-of-order: a token_count precedes the first turn_context.
        // Its tokens have no model yet, so they wait for the turn_context that names one
        // and become a turn there (see CodexEarlyTokenCountTests). Whatever happens to
        // them, its reading must become the baseline the NEXT token_count's delta is
        // computed against — otherwise the following turn would be billed as if the
        // counter had started from zero, wildly overcounting it.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 690),
            tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "the held tokens and the one that followed")
        // Correct: (800, 200, 0, 50, 10) recovered + delta (500, 100, 0, 30, 10) against
        // the carried baseline.
        // Buggy (baseline lost): the second delta would be the whole (1500, 300, 0, 80,
        // 20) reading again, counting the first turn's tokens twice.
        XCTAssertEqual(usage.breakdown.cacheRead, 300, "200 + 100, not 200 + 300")
        XCTAssertEqual(usage.breakdown.input, 1_200, "800 + max(0, 500 − 100), not 800 + 1200")
        XCTAssertEqual(usage.breakdown.output, 80, "50 + 30 — the baseline must have carried")
        XCTAssertEqual(usage.breakdown.thinking, 20)
        XCTAssertEqual(usage.tokens, 1_200 + 80 + 300)
    }

    // MARK: - B. Dollars

    func testEachBucketPricesAtItsOwnDistinctRateSoASwapWouldFail() async throws {
        ModelPricing.updateDynamic([
            "test-rates": ModelPrice(
                inputPerM: 2.0, outputPerM: 9.0, cacheReadPerM: 0.4,
                cacheCreate5mPerM: 6.0, cacheCreate1hPerM: 77.0
            )
        ])
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: "test-rates", cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 300, cacheWrite: 50, output: 80, reasoning: 0),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.breakdown.input, 700)
        XCTAssertEqual(usage.breakdown.cacheRead, 300)
        XCTAssertEqual(usage.breakdown.output, 80)
        XCTAssertEqual(usage.breakdown.cacheWrite5m, 50)

        let cost = try XCTUnwrap(usage.breakdown.cost)
        XCTAssertEqual(cost.input, 700 * 2.0 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 80 * 9.0 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 300 * 0.4 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheWrite, 50 * 6.0 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.total, 0.0014 + 0.00072 + 0.00012 + 0.0003, accuracy: 1e-9)
    }

    func testAnUnpricedModelKeepsItsTokensInTheFullBreakdownShape() async throws {
        let unknown = "no-such-codex-model-999"
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 60),
            turnContext(model: unknown, cwd: alphaCwd, secondsAgo: 60),
            tokenCount(secondsAgo: 1, input: 700, cached: 100, output: 40, reasoning: 5),
        ])

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.todayCost, 0)
        XCTAssertEqual(breakdown.todayTokenBreakdown.input, 600)
        XCTAssertEqual(breakdown.todayTokenBreakdown.cacheRead, 100)
        XCTAssertEqual(breakdown.todayTokenBreakdown.output, 40)
        XCTAssertNil(breakdown.todayTokenBreakdown.cost)
        XCTAssertEqual(breakdown.byModelToday.count, 1)
        XCTAssertEqual(breakdown.byModelToday[0].tokens, 740)
        XCTAssertNil(breakdown.byModelToday[0].breakdown.cost)
        XCTAssertEqual(breakdown.daily.count, 1)
        XCTAssertEqual(breakdown.daily[0].totalCost, 0)
        XCTAssertNil(breakdown.daily[0].tokens.cost)
        XCTAssertEqual(breakdown.daily[0].turns, 1)
    }

    func testADayMixingPricedAndUnpricedTurnsHasNoCategorySplitButCountsThePricedDollars() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 60),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 60),
            tokenCount(secondsAgo: 55, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-priced.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 50),
            turnContext(model: "unpriced-xyz", cwd: alphaCwd, secondsAgo: 50),
            tokenCount(secondsAgo: 45, input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-unpriced.jsonl")

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.daily.count, 1)
        let day = breakdown.daily[0]
        // Only the priced turn's dollars: 600×1.25/M + 400×0.125/M + 100×10/M.
        XCTAssertEqual(day.totalCost, 0.0018, accuracy: 1e-9, "the priced turn's dollars still count")
        XCTAssertNil(day.tokens.cost, "one turn of the day has no per-category split, so the day has none either")
        XCTAssertEqual(day.tokens.input, 600 + 500)
        XCTAssertEqual(day.tokens.cacheRead, 400)
        XCTAssertEqual(day.tokens.output, 150)
        XCTAssertEqual(day.totalTokens, day.tokens.total)
        XCTAssertEqual(breakdown.todayCost, 0.0018, accuracy: 1e-9)
        XCTAssertNil(breakdown.todayTokenBreakdown.cost)
    }

    // MARK: - C. Model attribution

    func testAModelChangeMidFileAttributesOnlyLaterDeltasToTheNewModel() async throws {
        ModelPricing.updateDynamic([
            "model-alpha-x": ModelPrice(inputPerM: 1, outputPerM: 2, cacheReadPerM: 0.1, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
            "model-beta-y": ModelPrice(inputPerM: 3, outputPerM: 4, cacheReadPerM: 0.2, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0),
        ])
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: "model-alpha-x", cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 200, output: 60, reasoning: 10),
            turnContext(model: "model-beta-y", cwd: alphaCwd, secondsAgo: 400),
            tokenCount(secondsAgo: 200, input: 1_800, cached: 500, output: 140, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.models.count, 2, "each turn's model attributes correctly, not merged")

        let alpha = try XCTUnwrap(usage.models.first { $0.model == "Model Alpha X" })
        XCTAssertEqual(alpha.tokens, 800 + 60 + 200, "only the first turn, before the model switch")
        XCTAssertEqual(alpha.breakdown.input, 800)
        XCTAssertEqual(alpha.breakdown.cacheRead, 200)
        XCTAssertEqual(alpha.breakdown.output, 60)

        let beta = try XCTUnwrap(usage.models.first { $0.model == "Model Beta Y" })
        // Delta against the running (not reset) cumulative baseline: (800, 300, 0, 80, 20).
        XCTAssertEqual(beta.breakdown.cacheRead, 300)
        XCTAssertEqual(beta.breakdown.input, 500, "max(0, 800 − 300); a reset baseline would give 1800 − 500 = 1300")
        XCTAssertEqual(beta.breakdown.output, 80)
        XCTAssertEqual(beta.tokens, 500 + 80 + 300)
    }

    // MARK: - D. Project identity

    func testProjectDisplayNameRoundTripsSpecialCharactersInTheCwd() async throws {
        let weirdCwd = "/tmp/Codex Verify/Weird (v2)!"
        try write([
            sessionMeta(cwd: weirdCwd, secondsAgo: 900),
            turnContext(model: model, cwd: weirdCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 0, output: 50, reasoning: 0),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.projects.count, 1)
        let expectedSlug = weirdCwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(usage.projects[0].slug, expectedSlug)
        XCTAssertEqual(usage.projects[0].displayName, "Codex Verify / Weird (v2)!")
    }

    func testTwoRolloutsWithTheSameCwdMergeIntoOneProject() async throws {
        let sharedCwd = "/tmp/Codex Verify/shared"
        try write([
            sessionMeta(cwd: sharedCwd, secondsAgo: 800),
            turnContext(model: model, cwd: sharedCwd, secondsAgo: 790),
            tokenCount(secondsAgo: 700, input: 600, cached: 0, output: 40, reasoning: 0),
        ], named: "rollout-shared-a.jsonl")
        try write([
            sessionMeta(cwd: sharedCwd, secondsAgo: 500),
            turnContext(model: model, cwd: sharedCwd, secondsAgo: 490),
            tokenCount(secondsAgo: 450, input: 300, cached: 0, output: 20, reasoning: 0),
        ], named: "rollout-shared-b.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.projects.count, 1, "same cwd, two files: one project")
        let project = usage.projects[0]
        XCTAssertEqual(project.turns, 2)
        XCTAssertEqual(project.totalTokens, 640 + 320)
        // The more recent of the two turns' timestamps (450s ago, not 700s ago).
        XCTAssertEqual(project.lastActivity.timeIntervalSince(now.addingTimeInterval(-450)), 0, accuracy: 1.5)
    }

    // MARK: - E. Windows

    func testDailyBucketsSplitOnLocalCalendarMidnightNotOnA24hRollingWindow() async throws {
        let midnight = Calendar.current.startOfDay(for: now)
        let beforeMidnight = midnight.addingTimeInterval(-60)
        let afterMidnight = midnight.addingTimeInterval(60)
        // Guard the same way the plan's own fixtures do: this only works away from the
        // midnight edge itself.
        try XCTSkipIf(now.timeIntervalSince(afterMidnight) < 0, "test running within a minute of local midnight")

        let secondsAgoBefore = now.timeIntervalSince(beforeMidnight)
        let secondsAgoAfter = now.timeIntervalSince(afterMidnight)
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: secondsAgoBefore + 10),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: secondsAgoBefore + 5),
            tokenCount(secondsAgo: secondsAgoBefore, input: 500, cached: 0, output: 50, reasoning: 0),
            tokenCount(secondsAgo: secondsAgoAfter, input: 1_200, cached: 0, output: 120, reasoning: 0),
        ])

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.daily.count, 2, "one turn either side of local midnight is two calendar days")
        XCTAssertEqual(breakdown.daily[0].tokens.total, 550)
        XCTAssertEqual(breakdown.daily[1].tokens.total, 770)
        XCTAssertEqual(breakdown.daily[1].day, midnight)
        XCTAssertEqual(breakdown.daily[0].day, Calendar.current.date(byAdding: .day, value: -1, to: midnight))
    }

    func testTodayTokenBreakdownIsExactlyTheSumOfTodaysTurnsExcludingYesterday() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 130),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 125),
            tokenCount(secondsAgo: 120, input: 1_000, cached: 200, output: 80, reasoning: 10),
        ], named: "rollout-today-1.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 65),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 62),
            tokenCount(secondsAgo: 60, input: 500, cached: 0, output: 30, reasoning: 0),
        ], named: "rollout-today-2.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 26 * 3600 + 30),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 26 * 3600 + 20),
            tokenCount(secondsAgo: 26 * 3600, input: 2_000, cached: 500, output: 200, reasoning: 0),
        ], named: "rollout-yesterday.jsonl")

        let breakdown = await loaded().breakdown()
        let today = breakdown.todayTokenBreakdown
        XCTAssertEqual(today.input, 800 + 500, "the 26h-old turn must not be counted as today")
        XCTAssertEqual(today.output, 80 + 30)
        XCTAssertEqual(today.cacheRead, 200)
        XCTAssertEqual(today.thinking, 10)
        XCTAssertEqual(today.total, breakdown.todayTokens)
        XCTAssertEqual(breakdown.todayTokens, 1_080 + 530)
    }

    func testWeekCostIsInclusiveAtExactlySevenDaysAndExclusiveBeyond() async throws {
        // A 30s margin either side of the exact 7×24h tick: wide enough to absorb the
        // real wall-clock gap between this test's frozen `now` (captured at instance
        // creation) and the moment `breakdown()` calls its own `Date()` — which grows
        // under load in the full suite — while still meaningfully pinning the cutoff
        // to "around 7 days", not some other boundary entirely.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 7 * 24 * 3600 + 100),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 7 * 24 * 3600 + 90),
            tokenCount(secondsAgo: 7 * 24 * 3600 - 30, input: 1_000, cached: 0, output: 100, reasoning: 0),
        ], named: "rollout-inside-week.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 7 * 24 * 3600 + 100),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 7 * 24 * 3600 + 90),
            tokenCount(secondsAgo: 7 * 24 * 3600 + 30, input: 2_000, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-outside-week.jsonl")

        let breakdown = await loaded().breakdown()
        // Inside: 1000×1.25/M + 100×10/M = 0.00225. Outside: 2000×1.25/M + 50×10/M = 0.003.
        XCTAssertEqual(breakdown.weekCost, 0.00225, accuracy: 1e-9, "the turn just past 7 days must be excluded")
        XCTAssertEqual(breakdown.monthCost, 0.00225 + 0.003, accuracy: 1e-9, "both are well inside 30 days")
        XCTAssertEqual(breakdown.todayCost, 0)
    }

    func testMonthCostIsInclusiveAtExactlyThirtyDaysAndExclusiveBeyond() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 30 * 24 * 3600 + 100),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 30 * 24 * 3600 + 90),
            tokenCount(secondsAgo: 30 * 24 * 3600 - 30, input: 1_000, cached: 0, output: 80, reasoning: 0),
        ], named: "rollout-inside-month.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 30 * 24 * 3600 + 100),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 30 * 24 * 3600 + 90),
            tokenCount(secondsAgo: 30 * 24 * 3600 + 30, input: 1_000, cached: 0, output: 40, reasoning: 0),
        ], named: "rollout-outside-month.jsonl")

        let breakdown = await loaded().breakdown()
        // Inside: 1000×1.25/M + 80×10/M = 0.00205. The turn just past 30 days is excluded.
        XCTAssertEqual(breakdown.monthCost, 0.00205, accuracy: 1e-9)
    }

    func testUsageWindowIncludesTurnsExactlyAtBothEndpoints() async throws {
        let start = exactInstant(100)
        let end = exactInstant(10)
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 150, input: 1_000, cached: 0, output: 50, reasoning: 0),
            tokenCount(secondsAgo: 100, input: 1_500, cached: 0, output: 80, reasoning: 0),   // == start
            tokenCount(secondsAgo: 10, input: 2_200, cached: 0, output: 120, reasoning: 0),   // == end
            tokenCount(secondsAgo: 5, input: 2_500, cached: 0, output: 140, reasoning: 0),
        ])

        let aggregator = await loaded()
        let usage = await aggregator.usage(from: start, to: end)
        XCTAssertEqual(usage.turns, 2, "the turn before start and the turn after end are excluded")
        XCTAssertEqual(usage.tokens, 530 + 740)
        XCTAssertEqual(usage.breakdown.input, 500 + 700)
        XCTAssertEqual(usage.breakdown.output, 30 + 40)
    }

    func testATurnJustPastTheRecentWindowIsFoldedAndStillAppearsInDailyWithItsSplit() async throws {
        let old: Double = 31 * 24 * 3600 + 3_600
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: old),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: old),
            tokenCount(secondsAgo: old, input: 1_500, cached: 300, output: 90, reasoning: 20),
        ], day: "2026/07/27", named: "rollout-past-recent-window.jsonl")

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.daily.count, 1)
        let day = breakdown.daily[0]
        XCTAssertEqual(day.totalTokens, day.tokens.total)
        XCTAssertEqual(day.tokens.input, 1_200)
        XCTAssertEqual(day.tokens.cacheRead, 300)
        XCTAssertEqual(day.tokens.output, 90)
        XCTAssertEqual(day.tokens.thinking, 20)
        XCTAssertEqual(day.totalCost, 0.0024375, accuracy: 1e-9)
        XCTAssertEqual(day.turns, 1)
        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertEqual(breakdown.monthCost, 0)
        XCTAssertEqual(breakdown.todayCost, 0)
    }

    func testModelsBreakdownInAWindowSumsAcrossMultipleTurnsOfTheSameModel() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 200, output: 60, reasoning: 10),
            tokenCount(secondsAgo: 400, input: 1_800, cached: 500, output: 140, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.models.count, 1, "both turns share one model")
        let m = usage.models[0]
        XCTAssertEqual(m.tokens, 1_060 + 880)
        XCTAssertEqual(m.breakdown.input, 800 + 500)
        XCTAssertEqual(m.breakdown.output, 60 + 80)
        XCTAssertEqual(m.breakdown.cacheRead, 200 + 300)
        XCTAssertEqual(m.breakdown.thinking, 10 + 20)
    }

    // MARK: - F. costs(now:), incremental tail, dedup

    func testCostsNowAgreesWithBreakdownAcrossThreeFilesWithoutAPriorRefresh() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 30),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 30),
            tokenCount(secondsAgo: 10, input: 1_000, cached: 0, output: 100, reasoning: 0),
        ], named: "rollout-today.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 3 * 24 * 3600),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 3 * 24 * 3600),
            tokenCount(secondsAgo: 3 * 24 * 3600 - 10, input: 500, cached: 0, output: 50, reasoning: 0),
        ], day: "2026/09/02", named: "rollout-3days.jsonl")
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 20 * 24 * 3600),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 20 * 24 * 3600),
            tokenCount(secondsAgo: 20 * 24 * 3600 - 10, input: 2_000, cached: 0, output: 200, reasoning: 0),
        ], day: "2026/08/16", named: "rollout-20days.jsonl")

        let fresh = CodexUsageAggregator(rootURL: root)
        let costs = await fresh.costs(now: now)
        let breakdown = await fresh.breakdown()
        XCTAssertEqual(costs.today, breakdown.todayCost, accuracy: 1e-9)
        XCTAssertEqual(costs.week, breakdown.weekCost, accuracy: 1e-9)
        // today: 1000×1.25/M + 100×10/M = 0.00225. week adds the 3-day-old turn: 500×1.25/M + 50×10/M = 0.001125.
        XCTAssertEqual(costs.today, 0.00225, accuracy: 1e-9)
        XCTAssertEqual(costs.week, 0.00225 + 0.001125, accuracy: 1e-9)
    }

    func testATruncatedFileIsReReadFromScratchNotSkippedForever() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-trunc.jsonl")
        let aggregator = await loaded()
        var usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)

        // Truncate to a size smaller than the consumed offset — the same file path,
        // shorter content, simulating a rewrite mid-session.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
        ], named: "rollout-trunc.jsonl")
        await aggregator.refresh()
        usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1, "truncation must not crash or fabricate a turn")

        // Now grow the file again, past the truncated size, with the SAME absolute
        // reading as the original first turn. A correct implementation treats this as
        // a brand-new baseline (delta = reading), producing a second turn identical in
        // shape to the first — not a stuck parser (consumed offset pinned past EOF)
        // that never reads anything again.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 500, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-trunc.jsonl")
        await aggregator.refresh()
        usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 2, "the file was re-read from scratch after truncation")
        XCTAssertEqual(usage.tokens, 2_200)
        XCTAssertEqual(usage.breakdown.input, 1_200)
        XCTAssertEqual(usage.breakdown.cacheRead, 800)
        XCTAssertEqual(usage.cost, 0.0036, accuracy: 1e-9)
    }

    func testATokenUsageRecordAndANullInfoEventNeitherCreateATurnNorTouchTheBaseline() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            // A bogus, much SMALLER reading under the wrong type — if this were
            // mistakenly parsed as the baseline, the real token_count below would show
            // a much bigger (wrong) delta than expected.
            tokenUsageRecord(secondsAgo: 650, input: 100, cached: 50, output: 10, reasoning: 5),
            nullInfoTokenCount(secondsAgo: 620),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "neither line produces a turn")
        XCTAssertEqual(usage.breakdown.input, 600, "the real reading, taken from a zero baseline")
        XCTAssertEqual(usage.breakdown.cacheRead, 400)
        XCTAssertEqual(usage.breakdown.output, 100)
        XCTAssertEqual(usage.tokens, 1_100)
    }
}

/// `DashboardState`'s Codex wiring, verified independently of `CostSourceTests`.
final class CodexDashboardWiringVerificationTests: XCTestCase {
    func testCostSourceForCodexIsALogSourceWithTheExactStrings() {
        let source = DashboardState.costSource(for: "codex")
        XCTAssertEqual(source, .log(shortName: "Codex CLI", longName: "the Codex CLI's session logs"))
        XCTAssertTrue(source.hasBreakdown)
        XCTAssertNil(source.reason)
    }

    func testCostAggregatorForCodexIsTheSharedSingletonInstance() {
        let aggregator = DashboardState.costAggregator(for: "codex")
        XCTAssertNotNil(aggregator)
        XCTAssertTrue(
            (aggregator as AnyObject?) === (CodexUsageAggregator.shared as AnyObject),
            "must be the same actor instance the rest of the app polls, not a fresh one"
        )
    }
}
