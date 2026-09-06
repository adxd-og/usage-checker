import XCTest
@testable import Omelette

/// Independent verification of the spec's Codex re-emit attack case that the
/// executor's own pinning test (`CodexUsageAggregatorTests.
/// testAReEmittedTokenCountIsNotASecondTurn`) does not cover: "three identical totals
/// then a genuine increase → exactly two turns". The executor's test proves repeats
/// collapse to *one* turn; this proves a real increase *after* repeats is still
/// counted, and counted exactly once — the over-counting bug (ccusage #1288) and its
/// opposite (a real turn getting swallowed by the repeat-suppression logic) both fail
/// this test.
///
/// Fixture shape (rollout JSONL) is copied verbatim from `CodexUsageAggregatorTests`
/// (Codex CLI 0.153.0, read 2026-09-05); those helpers are file-private there and
/// cannot be imported, so they are reproduced here rather than modifying that file.
final class CodexReEmitVerificationTests: XCTestCase {
    private var root: URL!
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let alphaCwd = "/tmp/Codex ReEmit Fixtures/alpha"
    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexReEmitVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func stamp(_ secondsAgo: Double) -> String { iso.string(from: now.addingTimeInterval(-secondsAgo)) }

    private func sessionMeta(cwd: String, secondsAgo: Double) -> String {
        let id = "01a07092-9e5d-7470-b491-400968478d34"
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":0,"type":"session_meta","payload":\
        {"session_id":"\(id)","id":"\(id)","timestamp":"\(stamp(secondsAgo))",\
        "cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.153.0","source":"exec",\
        "thread_source":"user","model_provider":"openai","history_mode":"default"}}
        """
    }

    private func turnContext(model: String, cwd: String, secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"01a07092-9ea2-7c40-8c17-f322bdc84724","cwd":"\(cwd)","workspace_roots":["\(cwd)"],\
        "current_date":"2026-09-05","timezone":"Europe/Vilnius","approval_policy":"never",\
        "model":"\(model)","personality":"default"}}
        """
    }

    private func tokenCount(secondsAgo: Double, input: Int, cached: Int, output: Int, reasoning: Int) -> String {
        let counters = "\"input_tokens\":\(input),\"cached_input_tokens\":\(cached)," +
            "\"cache_write_input_tokens\":0,\"output_tokens\":\(output)," +
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

    func testThreeIdenticalReadingsThenAGenuineIncreaseIsExactlyTwoTurns() async throws {
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            // Turn 1: the first reading ever seen for this session.
            tokenCount(secondsAgo: 700, input: 1_000, cached: 400, output: 100, reasoning: 30),
            // Two re-emits with the exact same cumulative totals — zero deltas.
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 500, input: 1_000, cached: 400, output: 100, reasoning: 30),
            // Turn 2: a genuine increase — new input, new output, no new cache read.
            tokenCount(secondsAgo: 400, input: 1_500, cached: 400, output: 150, reasoning: 40),
        ])

        let usage = await lastHour(loaded())

        XCTAssertEqual(usage.turns, 2, "the two repeats must add nothing, but the real increase must still count")
        // Turn 1: 600 fresh input + 400 cache read + 100 output = 1100.
        // Turn 2: 500 fresh input + 0 cache read (cached count unchanged) + 50 output = 550.
        XCTAssertEqual(usage.tokens, 1_650)
        XCTAssertEqual(usage.breakdown.input, 1_100, "600 (turn 1) + 500 (turn 2) fresh input")
        XCTAssertEqual(usage.breakdown.cacheRead, 400, "only turn 1 saw a cache-read delta")
        XCTAssertEqual(usage.breakdown.output, 150, "100 (turn 1) + 50 (turn 2)")
        // Turn 1 $0.0018 (600 in @1.25/M + 400 cache @0.125/M + 100 out @10/M)
        // Turn 2 $0.001125 (500 in @1.25/M + 0 cache + 50 out @10/M)
        XCTAssertEqual(usage.cost, 0.002925, accuracy: 1e-9)
    }

    func testFourIdenticalReadingsInARowStillAddNothingAtAll() async throws {
        // A stronger repeat count than the executor's own test (which uses two
        // repeats): the suppression must not "wear off" after a couple of re-emits.
        try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: 900),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: 890),
            tokenCount(secondsAgo: 700, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 500, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 400, input: 1_000, cached: 400, output: 100, reasoning: 30),
            tokenCount(secondsAgo: 300, input: 1_000, cached: 400, output: 100, reasoning: 30),
        ])

        let usage = await lastHour(loaded())

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)
    }
}
