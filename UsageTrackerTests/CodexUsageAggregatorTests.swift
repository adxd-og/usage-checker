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
}
