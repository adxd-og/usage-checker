import XCTest
@testable import Omelette

/// A rollout normally writes `turn_context` before its first `token_count`, so the
/// parser knows which model to bill each delta to. When it doesn't — a resumed thread
/// whose head we never read, a file written out of order — the delta used to be thrown
/// away. These fixtures pin the recovery: the tokens wait in the file's parse state and
/// the first `turn_context` that follows adopts them as one extra turn.
///
/// Fixture shape and the seeded rates are the ones `CodexUsageAggregatorTests` uses.
final class CodexEarlyTokenCountTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaCwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexEarlyTokenCountTests-\(UUID().uuidString)", isDirectory: true)
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
        let id = "01a07092-9e5d-7470-b491-400968478d33"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(id)","id":"\(id)","timestamp":"\(stamp(secondsAgo))",\
        "cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.153.0","source":"exec",\
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

    private func write(_ lines: [String], day: String = "2026/09/05") throws {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
    }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = CodexUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - Recovery

    func testAnEarlyTokenCountBecomesATurnUnderTheModelThatFollows() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 690),
            tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "the held delta is a turn of its own once a model names it")
        // The recovered turn is the whole first reading (800 fresh / 200 cached / 50 out);
        // the second is the delta against it, so the baseline still has to have carried.
        XCTAssertEqual(usage.breakdown.input, 1_200, "800 recovered + max(0, 500 − 100)")
        XCTAssertEqual(usage.breakdown.cacheRead, 300)
        XCTAssertEqual(usage.breakdown.output, 80)
        XCTAssertEqual(usage.breakdown.thinking, 20)
        XCTAssertEqual(usage.tokens, 1_200 + 80 + 300)

        XCTAssertEqual(usage.models.map(\.model), ["GPT 5.6 Terra"])
        XCTAssertEqual(usage.models[0].tokens, 1_580, "both turns are billed to that model")
    }

    /// The recovered turn is stamped when the tokens were spent, not when the model was
    /// finally named — a window that ends before the `turn_context` still contains it.
    func testTheRecoveredTurnKeepsTheEarliestTimestamp() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 690),
            tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
        ])

        let aggregator = await loaded()
        let early = await aggregator.usage(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(-695)
        )
        XCTAssertEqual(early.turns, 1)
        XCTAssertEqual(early.breakdown.input, 800)
        XCTAssertEqual(early.breakdown.cacheRead, 200)
        XCTAssertEqual(early.breakdown.output, 50)
    }

    func testTwoEarlyTokenCountsAreRecoveredAsOneTurn() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            tokenCount(secondsAgo: 650, input: 1_500, cached: 300, output: 80, reasoning: 20),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 640),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "one attribution point, one turn")
        XCTAssertEqual(usage.breakdown.input, 1_200, "800 + max(0, 500 − 100)")
        XCTAssertEqual(usage.breakdown.cacheRead, 300)
        XCTAssertEqual(usage.breakdown.output, 80)
    }

    /// No `turn_context` anywhere: there is no model to price the tokens with and no
    /// name to show them under, so they stay unrecorded rather than being guessed at.
    func testAFileThatNeverNamesAModelRecordsNothing() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            tokenCount(secondsAgo: 600, input: 1_500, cached: 300, output: 80, reasoning: 20),
        ])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 0)
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertEqual(usage.cost, 0)
    }

    func testTheRecoveredTurnIsPricedIntoTheRollingCosts() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 200, output: 50, reasoning: 10),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 690),
        ])

        // 800 fresh input @ $1.25/M + 200 cache read @ $0.125/M + 50 output @ $10/M.
        let costs = await CodexUsageAggregator(rootURL: root).costs(now: now)
        XCTAssertEqual(costs.week, 0.001525, accuracy: 1e-9)
    }
}
