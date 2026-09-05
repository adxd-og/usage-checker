import XCTest
@testable import Omelette

/// Fixture rollouts mimic what the Codex CLI writes to
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`: `session_meta` on line 1,
/// a `turn_context` naming the model, then `event_msg` / `token_count` events whose
/// `info.total_token_usage` is **cumulative**. Every field name below is copied from a
/// real rollout (Codex CLI 0.153.0, read 2026-09-05).
///
/// models.dev never loads in this target, so the rates the dollar assertions are
/// computed from are seeded into `ModelPricing.updateDynamic` and cleared in teardown.
final class CodexUsageAggregatorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    /// Deliberately outside the tester's home directory: `ProjectName` strips a home
    /// prefix, and a fixture whose display name moved with whoever ran the suite would
    /// be untestable.
    private let alphaCwd = "/tmp/Codex Fixtures/alpha app"
    private let betaCwd = "/tmp/Codex Fixtures/beta"
    private let alphaName = "Codex Fixtures / alpha app"
    private let betaName = "Codex Fixtures / beta"

    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // `dynamicLookup` strips variant suffixes, so "gpt-5.6-terra" resolves to this
        // row. Cache-create rates are zero because OpenAI does not bill cache writes —
        // the same thing models.dev reports.
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 0, cacheCreate1hPerM: 0
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        // `ModelPricing.dynamicTable` is process-global; a test that seeds it must not
        // leave rates behind for the next one.
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Fixture writing

    /// An instance property, not a static one: a `static let` of a non-Sendable type
    /// would need `nonisolated(unsafe)`, and one formatter per test case costs nothing.
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
        let id = "01a07092-9e5d-7470-b491-400968478d33"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(id)","id":"\(id)","timestamp":"\(stamp(secondsAgo))",\
        "cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.153.0","source":"exec",\
        "thread_source":"user","model_provider":"openai","history_mode":"default"}}
        """
    }

    /// `cwd: nil` omits the field, for the fallback tests.
    private func turnContext(model: String, cwd: String?, secondsAgo: Double) -> String {
        let cwdField = cwd.map { "\"cwd\":\"\($0)\",\"workspace_roots\":[\"\($0)\"]," } ?? ""
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"01a07092-9ea2-7c40-8c17-f322bdc84723",\(cwdField)\
        "current_date":"2026-09-05","timezone":"Europe/Vilnius","approval_policy":"never",\
        "model":"\(model)","personality":"default"}}
        """
    }

    /// One cumulative reading. `last_token_usage` is written the way the CLI writes it
    /// and is deliberately ignored by the parser.
    private func tokenCount(
        secondsAgo: Double,
        input: Int,
        cached: Int,
        cacheWrite: Int = 0,
        output: Int,
        reasoning: Int
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

    @discardableResult
    private func write(
        _ lines: [String],
        day: String = "2026/09/05",
        named name: String = "rollout-a.jsonl"
    ) throws -> URL {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The canonical fixture: three cumulative readings, the third a counter reset.
    ///
    ///   e1 Δ in 1000 / cached 400 / write 0 / out 100 / reasoning 30
    ///   e2 Δ in 2000 / cached 1000 / write 200 / out 200 / reasoning 60
    ///   e3 counter restarts at 500/100/0/50/10 — the reading is the delta
    private func writeThreeReadings(cwd: String? = nil, named name: String = "rollout-a.jsonl") throws {
        let dir = cwd ?? alphaCwd
        try write([
            sessionMeta(cwd: dir, secondsAgo: 900),
            turnContext(model: model, cwd: dir, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 400, input: 3_000, cached: 1_400, cacheWrite: 200, output: 300, reasoning: 90),
            tokenCount(secondsAgo: 200, input: 500, cached: 100, output: 50, reasoning: 10),
        ], named: name)
    }

    // MARK: - Injection

    func testTheAggregatorReadsTheInjectedRoot() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        // 600 fresh input @ $1.25/M + 400 cache read @ $0.125/M + 100 output @ $10/M.
        let costs = await CodexUsageAggregator(rootURL: root).costs(now: now)
        XCTAssertEqual(costs.week, 0.0018, accuracy: 1e-9)
        XCTAssertEqual(costs.today, 0.0018, accuracy: 1e-9)
    }

    // MARK: - Per-delta breakdown

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = CodexUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    func testCumulativeCountersBecomePerTurnBreakdowns() async throws {
        try writeThreeReadings()

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 3)
        XCTAssertEqual(usage.tokens, 4_050)

        // Fresh input is input − cached, so the five buckets are disjoint and sum to
        // the total; thinking is a subset of output and is not in it.
        let b = usage.breakdown
        XCTAssertEqual(b.input, 2_000)
        XCTAssertEqual(b.output, 350)
        XCTAssertEqual(b.cacheRead, 1_500)
        XCTAssertEqual(b.cacheWrite5m, 200)
        XCTAssertEqual(b.cacheWrite1h, 0)
        XCTAssertEqual(b.thinking, 100)
        XCTAssertEqual(b.total, 4_050)

        let cost = try XCTUnwrap(b.cost)
        XCTAssertEqual(cost.input, 0.0025, accuracy: 1e-12)
        XCTAssertEqual(cost.output, 0.0035, accuracy: 1e-12)
        XCTAssertEqual(cost.cacheRead, 0.0001875, accuracy: 1e-12)
        XCTAssertEqual(cost.cacheWrite, 0, accuracy: 1e-12, "OpenAI does not bill cache writes")
        // The turn's dollars and the breakdown's dollars are the same number.
        XCTAssertEqual(cost.total, 0.0061875, accuracy: 1e-12)
        XCTAssertEqual(usage.cost, 0.0061875, accuracy: 1e-12)
    }

    func testANegativeDeltaRestartsTheBaseline() async throws {
        try writeThreeReadings()

        // Only the third reading, whose counter restarted at 500/100/0/50/10. Read as a
        // delta against the previous 3000 it would be −2500; it is the delta itself.
        let aggregator = await loaded()
        let third = await aggregator.usage(from: now.addingTimeInterval(-300), to: now)
        XCTAssertEqual(third.turns, 1)
        XCTAssertEqual(third.tokens, 550)
        XCTAssertEqual(third.breakdown.input, 400)
        XCTAssertEqual(third.breakdown.cacheRead, 100)
        XCTAssertEqual(third.breakdown.output, 50)
        XCTAssertEqual(third.breakdown.thinking, 10)
        XCTAssertEqual(third.cost, 0.0010125, accuracy: 1e-12)
    }

    func testTheOtherLineTypesAreIgnored() async throws {
        // `token_usage_record` sits next to every `token_count` in a real rollout and
        // restates the same counters; billing it would double every figure. A
        // `token_count` whose `info` is null appears in real logs too.
        let record = """
        {"timestamp":"\(stamp(500))","ordinal":15,"type":"token_usage_record","payload":\
        {"thread_id":"t","turn_id":"u","usage":{"input_tokens":1000,"cached_input_tokens":400,\
        "cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":30,\
        "total_tokens":1100}}}
        """
        let nullInfo = """
        {"timestamp":"\(stamp(450))","ordinal":16,"type":"event_msg","payload":\
        {"type":"token_count","info":null,"rate_limits":null}}
        """
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            record,
            nullInfo,
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testARepeatedReadingAddsNothing() async throws {
        // The counter is cumulative, so an event that repeats the previous reading has
        // a zero delta and is not a turn.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 500, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)
    }

    func testOnlyTheAppendedTailIsParsedOnASecondRefresh() async throws {
        let head = [
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ]
        try write(head)
        let aggregator = await loaded()

        // Re-reading the file from byte 0 with a fresh baseline would bill the first
        // reading twice; the carried offset and baseline are what stop it.
        await aggregator.refresh()
        var usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)

        try write(head + [
            tokenCount(secondsAgo: 300, input: 3_000, cached: 1_400, cacheWrite: 200, output: 300, reasoning: 90),
        ])
        await aggregator.refresh()

        usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.tokens, 3_500)
        XCTAssertEqual(usage.breakdown.cacheWrite5m, 200)
        XCTAssertEqual(usage.cost, 0.0051750, accuracy: 1e-12)
    }

    func testAWindowSumsOnlyTheTurnsInsideIt() async throws {
        try writeThreeReadings()
        let aggregator = await loaded()

        let outside = await aggregator.usage(
            from: now.addingTimeInterval(-2 * 3600),
            to: now.addingTimeInterval(-3600)
        )
        XCTAssertTrue(outside.isEmpty)
        XCTAssertEqual(outside.cost, 0)
        XCTAssertEqual(outside.breakdown, .zero)
    }

    func testAnEmptyLogRootProducesNothing() async throws {
        let usage = await lastHour(loaded())
        XCTAssertTrue(usage.isEmpty)
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertEqual(usage.breakdown, .zero)
    }

    // MARK: - Unpriced models

    func testAnUnpricedModelKeepsItsTokensAtZeroCost() async throws {
        // Nothing in the seeded table matches this id at any suffix depth, so
        // `dynamicLookup` returns nil.
        let unknown = "no-such-model-xyz"
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: unknown, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "an unpriceable turn is still activity")
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.breakdown.input, 600)
        XCTAssertEqual(usage.breakdown.cacheRead, 400)
        XCTAssertEqual(usage.breakdown.output, 100)
        XCTAssertEqual(usage.cost, 0, accuracy: 1e-12)
        XCTAssertNil(usage.breakdown.cost, "no rates, so no per-category dollars to invent")
        XCTAssertEqual(usage.models.map(\.model), ["No Such Model Xyz"])
        XCTAssertNil(usage.models.first?.breakdown.cost)
    }

    func testAPricedAndAnUnpricedTurnTogetherReportNoCategorySplit() async throws {
        // `TokenBreakdown.+` drops `cost` when either side has none: a total that
        // silently omitted the unpriced half would be worse than no split at all.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
            turnContext(model: "no-such-model-xyz", cwd: alphaCwd, secondsAgo: 500),
            tokenCount(secondsAgo: 400, input: 1_500, cached: 400, output: 150, reasoning: 30),
        ], named: "rollout-mixed.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12, "only the priced turn has dollars")
        XCTAssertNil(usage.breakdown.cost)
        XCTAssertEqual(usage.tokens, 1_650)
    }

    // MARK: - Project identity

    func testProjectNamesComeFromTheSessionMetaCwd() async throws {
        try writeThreeReadings(cwd: alphaCwd, named: "rollout-alpha.jsonl")
        try write([
            sessionMeta(cwd: betaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: betaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-beta.jsonl")

        let usage = await lastHour(loaded())
        // Ranked by cost: alpha spent $0.0061875, beta $0.001125.
        XCTAssertEqual(usage.projects.map(\.displayName), [alphaName, betaName])
        XCTAssertEqual(usage.projects[0].totalCost, 0.0061875, accuracy: 1e-12)
        XCTAssertEqual(usage.projects[1].totalCost, 0.001125, accuracy: 1e-12)
        // The slug is the percent-encoded cwd, the same shape Grok's directories have.
        XCTAssertEqual(usage.projects[1].slug, "%2Ftmp%2FCodex%20Fixtures%2Fbeta")
    }

    func testTheTurnContextCwdStandsInForAMissingSessionMeta() async throws {
        // A rollout whose first line we never saw — the parser starts mid-file.
        try write([
            turnContext(model: model, cwd: betaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-nometa.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.projects.map(\.displayName), [betaName])
    }

    func testTheFileBasenameIsTheLastResort() async throws {
        try write([
            turnContext(model: model, cwd: nil, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-nowhere.jsonl")

        let usage = await lastHour(loaded())
        // Not an encoded absolute path, so `ProjectName` hands it back verbatim rather
        // than inventing a directory for it.
        XCTAssertEqual(usage.projects.map(\.displayName), ["rollout-nowhere"])
    }

    // MARK: - breakdown()

    func testBreakdownFillsTheShapeTheDashboardRenders() async throws {
        // One second ago, not ten minutes: a "today" turn placed ten minutes back falls
        // into yesterday whenever the suite runs between 00:00 and 00:10.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 60),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 60),
            tokenCount(secondsAgo: 1, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-today.jsonl")
        try write([
            sessionMeta(cwd: betaCwd, secondsAgo: 2 * 24 * 3600),
            turnContext(model: model, cwd: betaCwd, secondsAgo: 2 * 24 * 3600),
            tokenCount(secondsAgo: 2 * 24 * 3600, input: 500, cached: 0, output: 50, reasoning: 0),
        ], day: "2026/09/03", named: "rollout-old.jsonl")

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.todayCost, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(breakdown.todayTokens, 1_100)
        XCTAssertEqual(breakdown.todayTurns, 1)
        XCTAssertEqual(breakdown.weekCost, 0.002925, accuracy: 1e-12)
        XCTAssertEqual(breakdown.monthCost, 0.002925, accuracy: 1e-12)

        // `todayTokens` and the card's breakdown are the same tokens.
        XCTAssertEqual(breakdown.todayTokenBreakdown.total, breakdown.todayTokens)
        XCTAssertEqual(breakdown.todayTokenBreakdown.input, 600)
        XCTAssertEqual(breakdown.todayTokenBreakdown.cacheRead, 400)
        XCTAssertEqual(breakdown.todayTokenBreakdown.output, 100)
        XCTAssertEqual(breakdown.todayTokenBreakdown.thinking, 30)
        XCTAssertEqual(breakdown.todayTokenBreakdown.cost?.total ?? -1, 0.0018, accuracy: 1e-12)

        XCTAssertEqual(breakdown.byModelToday.map(\.model), ["GPT 5.6 Terra"])
        XCTAssertEqual(breakdown.byModelToday[0].tokens, 1_100)
        XCTAssertEqual(breakdown.byModelToday[0].breakdown.cacheRead, 400)

        // Two calendar days, oldest first; each daily row's totalTokens is its
        // breakdown's total.
        XCTAssertEqual(breakdown.daily.count, 2)
        for day in breakdown.daily {
            XCTAssertEqual(day.totalTokens, day.tokens.total)
        }
        XCTAssertEqual(breakdown.daily.last?.tokens.output, 100)
        XCTAssertEqual(breakdown.projectsWeek.map(\.displayName), [alphaName, betaName])
    }

    func testATurnOlderThanTheRecentWindowStillHasItsDay() async throws {
        // 40 days back: folded into `oldDays` and released from `recentTurns`, but the
        // History chart still has to be able to draw it.
        let old: Double = 40 * 24 * 3600
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: old),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: old),
            tokenCount(secondsAgo: old, input: 1_000, cached: 0, output: 100, reasoning: 0),
        ], day: "2026/07/27", named: "rollout-ancient.jsonl")

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.daily.count, 1)
        XCTAssertEqual(breakdown.daily[0].totalTokens, 1_100)
        XCTAssertEqual(breakdown.daily[0].tokens.input, 1_000)
        XCTAssertEqual(breakdown.daily[0].tokens.output, 100)
        XCTAssertEqual(breakdown.daily[0].totalCost, 0.00225, accuracy: 1e-12)
        XCTAssertEqual(breakdown.daily[0].turns, 1)
        XCTAssertEqual(breakdown.weekCost, 0, "40 days ago is in no rolling window")
        XCTAssertEqual(breakdown.monthCost, 0)
        XCTAssertEqual(breakdown.todayCost, 0)
    }

    func testTheProtocolIsSatisfied() async throws {
        // The dashboard reaches every aggregator through this protocol; conformance is
        // the whole point of the package.
        let aggregator: any CostLogAggregating = CodexUsageAggregator(rootURL: root)
        await aggregator.refresh()
        let breakdown = await aggregator.breakdown()
        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertTrue(breakdown.daily.isEmpty)
    }
}
