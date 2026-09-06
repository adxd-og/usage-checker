import XCTest
@testable import Omelette

/// Independent verification of the Codex cache-accounting fix (commit 2055ead: OpenAI's
/// `ordinary_input = input − cached − cache_write`, all three inside `input_tokens`, and
/// cache writes billed from GPT-5.6 on) and the models.dev inference rule
/// (`ModelsDevPricing.inferredCacheWrite5m`). Written without reading
/// `CodexUsageAggregatorTests`; focuses on the clamp when a delta's cached+write
/// exceeds its input, the end-to-end pipeline from a raw models.dev fixture through
/// `ModelPricing.updateDynamic` into a parsed Codex turn, and the two OpenAI lines the
/// spec names explicitly as billing no cache writes at all.
final class CodexCacheWriteAccountingVerificationTests: XCTestCase {
    private var root: URL!
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Verify Fixtures/proj"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCacheWriteAccountingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    private func sessionMeta(secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","type":"session_meta","payload":\
        {"id":"s1","cwd":"\(cwd)","originator":"codex_exec"}}
        """
    }

    private func turnContext(model: String, secondsAgo: Double) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","type":"turn_context","payload":\
        {"model":"\(model)"}}
        """
    }

    private func tokenCount(
        secondsAgo: Double, input: Int, cached: Int, cacheWrite: Int, output: Int, reasoning: Int = 0
    ) -> String {
        """
        {"timestamp":"\(stamp(secondsAgo))","type":"event_msg","payload":\
        {"type":"token_count","info":{"total_token_usage":{\
        "input_tokens":\(input),"cached_input_tokens":\(cached),\
        "cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output),\
        "reasoning_output_tokens":\(reasoning),"total_tokens":\(input + output)}}}}
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

    // MARK: - Clamp when cached + write exceeds input

    func testADeltaWhoseCachedPlusWriteExceedsInputClampsFreshInputToZeroNotNegative() async throws {
        // A malformed or unusual delta: 800 fresh input on paper, but 1_000 cached +
        // 500 write already claim more than the whole input counter. `max(0, ...)` must
        // win, never a negative "fresh input".
        let model = "gpt-5.6-nova"
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(inputPerM: 2, outputPerM: 8, cacheReadPerM: 0.2, cacheCreate5mPerM: 2.5, cacheCreate1hPerM: 4),
        ])
        try write([
            sessionMeta(secondsAgo: 900),
            turnContext(model: model, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 800, cached: 1_000, cacheWrite: 500, output: 50),
        ])

        let usage = await lastHour(loaded())
        let b = usage.breakdown
        XCTAssertEqual(b.input, 0, "1_000 + 500 already exceeds 800; fresh input clamps to 0, not −700")
        XCTAssertEqual(b.cacheRead, 1_000, "the raw cached counter is reported as-is")
        XCTAssertEqual(b.cacheWrite5m, 500, "the raw write counter is reported as-is")
        XCTAssertEqual(b.output, 50)
        XCTAssertEqual(b.total, 1_550, "0 + 1_000 + 500 + 50, never negative")
        XCTAssertGreaterThanOrEqual(b.input, 0)

        let cost = try XCTUnwrap(b.cost)
        XCTAssertEqual(cost.input, 0, accuracy: 1e-12)
        XCTAssertEqual(cost.cacheRead, 1_000 * 0.2 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(cost.cacheWrite, 500 * 2.5 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(cost.output, 50 * 8.0 / 1_000_000, accuracy: 1e-12)
        XCTAssertEqual(cost.total, 0.00185, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(cost.total, 0)
    }

    func testFreshInputCachedAndWriteAlwaysSumBackToTheRawInputCounterWhenNotClamped() async throws {
        let model = "gpt-5.6-nova"
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(inputPerM: 2, outputPerM: 8, cacheReadPerM: 0.2, cacheCreate5mPerM: 2.5, cacheCreate1hPerM: 4),
        ])
        try write([
            sessionMeta(secondsAgo: 900),
            turnContext(model: model, secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 10_000, cached: 3_000, cacheWrite: 1_000, output: 400, reasoning: 100),
        ])

        let usage = await lastHour(loaded())
        let b = usage.breakdown
        XCTAssertEqual(b.input, 6_000)
        XCTAssertEqual(b.cacheRead, 3_000)
        XCTAssertEqual(b.cacheWrite5m, 1_000)
        XCTAssertEqual(b.input + b.cacheRead + b.cacheWrite5m, 10_000, "the three input-side buckets restore the raw counter")
        XCTAssertEqual(b.total, 6_000 + 3_000 + 1_000 + 400, "fresh + cached + write + output")
        XCTAssertEqual(b.thinking, 100, "reasoning is inside output, not added to the total")
    }

    // MARK: - Explicit models.dev cache_write wins over the inferred 1.25x rule, end to end

    func testAnExplicitModelsDevCacheWriteRateWinsOverTheInferredRuleThroughTheFullPipeline() async throws {
        // Parse a models.dev-shaped payload where gpt-6-nova publishes its own
        // cache_write (deliberately NOT 1.25x its input, so an inferring build would
        // read a different number), feed it through the same `updateDynamic` the real
        // refresh path uses, and confirm the Codex aggregator's dollars follow the
        // published rate, not the inference.
        let root: [String: Any] = [
            "openai": ["models": [
                "gpt-6-nova": ["cost": ["input": 10.0, "output": 40.0, "cache_read": 1.0, "cache_write": 9.0]],
            ]],
        ]
        let prices = try ModelsDevPricing.parse(root)
        ModelPricing.updateDynamic(prices)

        try write([
            sessionMeta(secondsAgo: 900),
            turnContext(model: "gpt-6-nova", secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 5_000, cached: 0, cacheWrite: 2_000, output: 0),
        ])

        let usage = await lastHour(loaded())
        let cost = try XCTUnwrap(usage.breakdown.cost)
        // 2_000 writes at the published $9/M, NOT the inferred 1.25 x $10/M = $12.5/M.
        XCTAssertEqual(cost.cacheWrite, 2_000 * 9.0 / 1_000_000, accuracy: 1e-9)
        XCTAssertNotEqual(cost.cacheWrite, 2_000 * 12.5 / 1_000_000, accuracy: 1e-12)
    }

    func testAModelWithNoPublishedCacheWriteInfersTheRateThroughTheFullPipeline() async throws {
        // Same pipeline, but gpt-6-luna publishes no cache_write at all — the loader
        // must infer 1.25x its input rate because it is a GPT-6 line.
        let root: [String: Any] = [
            "openai": ["models": [
                "gpt-6-luna": ["cost": ["input": 8.0, "output": 32.0]],
            ]],
        ]
        let prices = try ModelsDevPricing.parse(root)
        ModelPricing.updateDynamic(prices)

        try write([
            sessionMeta(secondsAgo: 900),
            turnContext(model: "gpt-6-luna", secondsAgo: 890),
            tokenCount(secondsAgo: 600, input: 1_000, cached: 0, cacheWrite: 500, output: 0),
        ])

        let usage = await lastHour(loaded())
        let cost = try XCTUnwrap(usage.breakdown.cost)
        XCTAssertEqual(cost.cacheWrite, 500 * (8.0 * 1.25) / 1_000_000, accuracy: 1e-9)
    }

    // MARK: - Lines the spec names explicitly as billing no cache writes

    func testGPT55AndGPT41InferAZeroCacheWriteRate() {
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "openai", modelID: "gpt-5.5", inputPerM: 3), 0,
            "GPT-5.5 predates GPT-5.6's cache-write billing"
        )
        XCTAssertEqual(
            ModelsDevPricing.inferredCacheWrite5m(provider: "openai", modelID: "gpt-4.1", inputPerM: 2), 0,
            "GPT-4.1 is well before the cache-write line"
        )
        XCTAssertFalse(ModelsDevPricing.billsCacheWrites(openAIModelID: "gpt-5.5"))
        XCTAssertFalse(ModelsDevPricing.billsCacheWrites(openAIModelID: "gpt-4.1"))
    }

    func testGPT55AndGPT41ProduceNoCacheWriteDollarsThroughTheFullPipeline() async throws {
        for model in ["gpt-5.5", "gpt-4.1"] {
            let root: [String: Any] = [
                "openai": ["models": [model: ["cost": ["input": 3.0, "output": 12.0]]]],
            ]
            let prices = try ModelsDevPricing.parse(root)
            ModelPricing.updateDynamic(prices)

            let aggRoot = self.root.appendingPathComponent("byModel", isDirectory: true)
                .appendingPathComponent(model, isDirectory: true)
            try FileManager.default.createDirectory(at: aggRoot, withIntermediateDirectories: true)
            let dir = aggRoot.appendingPathComponent("2026/09/05", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let lines = [
                sessionMeta(secondsAgo: 900),
                turnContext(model: model, secondsAgo: 890),
                tokenCount(secondsAgo: 600, input: 1_000, cached: 0, cacheWrite: 500, output: 0),
            ]
            try (lines.joined(separator: "\n") + "\n")
                .write(to: dir.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

            let aggregator = CodexUsageAggregator(rootURL: aggRoot)
            await aggregator.refresh()
            let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
            let cost = try XCTUnwrap(usage.breakdown.cost)
            XCTAssertEqual(cost.cacheWrite, 0, accuracy: 1e-12, "\(model) must not bill its 500 written tokens")
        }
        ModelPricing.updateDynamic([:])
    }
}
