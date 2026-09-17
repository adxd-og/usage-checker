import XCTest
@testable import Omelette

/// Independent verification of `CodexUsageAggregator`'s half of the year-retention
/// design: the 366-day `mtimeWindow` and the separate `dayRetention` constant. Written
/// from the spec and the diff, with its own fixtures — never the executor's test file.
///
/// Fixture shape copied from `CodexUsageAggregatorTests.swift`: `session_meta` /
/// `turn_context` / `token_count` event lines, as the Codex CLI actually writes them.
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Facts, § Retention, § Codex and Grok, § Tests.
final class CodexYearRetentionVerificationTests: XCTestCase {
    private var root: URL!
    /// Anchored at least an hour into the local day, same reasoning as the executor's
    /// own fixture clock: a suite running just after local midnight must not file a
    /// "today" fixture under yesterday.
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()

    private let alphaCwd = "/tmp/Codex Retention Verification/alpha app"
    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexYearRetentionVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // `dynamicLookup` strips variant suffixes, so "gpt-5.6-terra" resolves to this
        // row. No hardcoded static table entry exists for a GPT-5.6 model, by design.
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

    private func turnContext(model: String, cwd: String, secondsAgo: Double) -> String {
        return """
        {"timestamp":"\(stamp(secondsAgo))","ordinal":7,"type":"turn_context","payload":\
        {"turn_id":"01a07092-9ea2-7c40-8c17-f322bdc84723","cwd":"\(cwd)",\
        "workspace_roots":["\(cwd)"],"current_date":"2026-01-01","timezone":"UTC",\
        "approval_policy":"never","model":"\(model)","personality":"default"}}
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
    private func write(
        _ lines: [String], day: String = "2026/01/01", named name: String = "rollout-a.jsonl"
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

    // MARK: - Retention: a year of day totals

    /// The mtime AND the turn's own timestamp are both ~300 days old — the shape a
    /// rollout has when nobody has touched that project in ten months. `mtimeWindow`
    /// is 366 days, so the scanner must still parse it and its day must reach `daily`.
    func testARolloutAboutTenMonthsOldReachesTheDailyTotals() async throws {
        let old: Double = 300 * 24 * 3600
        let url = try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: old),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: old),
            tokenCount(secondsAgo: old, input: 2_000, cached: 0, output: 200, reasoning: 0),
        ], named: "rollout-300d.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-old)], ofItemAtPath: url.path
        )

        let breakdown = await loaded().breakdown()
        let expectedDay = Calendar.current.startOfDay(for: now.addingTimeInterval(-old))

        XCTAssertEqual(breakdown.daily.map(\.day), [expectedDay])
        // Fresh input 2,000 @ $1.25/M + output 200 @ $10/M = $0.0025 + $0.002 = $0.0045.
        XCTAssertEqual(breakdown.daily.first?.totalCost ?? 0, 0.0045, accuracy: 1e-9)
    }

    /// The mirror case: a rollout ~400 days old, past the 366-day `mtimeWindow`. It
    /// must never be parsed, so its day must not appear in `daily` at all.
    func testARolloutAboutThirteenMonthsOldNeverReachesTheDailyTotals() async throws {
        let old: Double = 400 * 24 * 3600
        let url = try write([
            sessionMeta(cwd: alphaCwd, secondsAgo: old),
            turnContext(model: model, cwd: alphaCwd, secondsAgo: old),
            tokenCount(secondsAgo: old, input: 2_000, cached: 0, output: 200, reasoning: 0),
        ], named: "rollout-400d.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-old)], ofItemAtPath: url.path
        )

        let breakdown = await loaded().breakdown()

        XCTAssertTrue(breakdown.daily.isEmpty, "past the 366-day mtime window the rollout must never be parsed")
        XCTAssertEqual(breakdown.todayCost, 0, "nothing from a skipped rollout may reach today's figures either")
    }
}
