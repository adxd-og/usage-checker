import XCTest
@testable import Omelette

/// Independent verification of `GrokUsageAggregator`'s token split, written without
/// reading `GrokUsageAggregatorTests`. Covers the corners the spec calls out: fresh
/// input clamped at zero when the CLI's own cached-read counter exceeds its input
/// counter, `cacheWrite5m` mirroring `cacheCreationTokens` directly, `cost == nil` at
/// every level (model, day, window), the headline token count staying the CLI's own
/// figure even when a model row's reported total actively disagrees with its parts, a
/// multi-model turn's per-model breakdowns summing to the turn/window breakdown, and
/// negative raw counters clamped to zero rather than going negative or corrupting the
/// share-based cost split.
final class GrokUsageAggregatorVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let projectDir = "%2Ftmp%2FGrokVerify%2Fproject"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokUsageAggregatorVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Fixture writing (independent low-level builder: full control per model row)

    /// One `modelUsage` entry, every field given explicitly so a test can set a row's
    /// reported `totalTokens` independently of its `inputTokens`/`outputTokens`, or drive
    /// any counter negative — things the higher-level fixture builders in the executor's
    /// suite don't need to express.
    private func modelEntry(
        input: Int, output: Int, cachedRead: Int = 0, cacheCreation: Int = 0,
        total: Int? = nil, ticks: Int? = nil
    ) -> String {
        let totalTokens = total ?? (input + output)
        var s = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(totalTokens),"
        s += "\"cachedReadTokens\":\(cachedRead),\"cacheCreationTokens\":\(cacheCreation)"
        if let ticks { s += ",\"costUsdTicks\":\(ticks)" }
        return s
    }

    private func turnLine(
        eventID: String, secondsAgo: Double, models: [String: String], session: String = "sess-1"
    ) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        let modelUsage = models.map { "\"\($0.key)\":{\($0.value)}" }.joined(separator: ",")
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"\(session)",\
        "update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{\(modelUsage)}}},\
        "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    private func write(_ lines: [String], project: String? = nil, session: String = "session-uuid") throws {
        let dir = root
            .appendingPathComponent(project ?? projectDir, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
    }

    private func loaded() async -> GrokUsageAggregator {
        let aggregator = GrokUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: GrokUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - Fresh input clamps at zero when cached read exceeds input

    func testFreshInputClampsToZeroWhenCachedReadExceedsRawInput() async throws {
        // A data glitch the CLI itself could log (or a boundary the aggregator must
        // defend against regardless): cachedReadTokens > inputTokens. `max(0, input -
        // cacheRead)` must floor at 0, never go negative.
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: ["grok-4.6-build": modelEntry(input: 100, output: 5, cachedRead: 150, ticks: 100_000_000)]
        )])

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(model.breakdown.input, 0, "fresh input must floor at zero, not go negative")
        XCTAssertEqual(model.breakdown.cacheRead, 150, "the reported cache read itself is untouched")
        XCTAssertEqual(usage.breakdown.input, 0)
    }

    // MARK: - cacheWrite5m mirrors cacheCreationTokens directly

    func testCacheWrite5mIsExactlyCacheCreationTokensAndCacheWrite1hIsAlwaysZero() async throws {
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: ["grok-4.6-build": modelEntry(input: 1_000, output: 10, cacheCreation: 4_321, ticks: 100_000_000)]
        )])

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(model.breakdown.cacheWrite5m, 4_321)
        XCTAssertEqual(model.breakdown.cacheWrite1h, 0, "the CLI has no 1h cache-write concept")
        XCTAssertEqual(model.breakdown.cacheWrite, 4_321)
    }

    // MARK: - cost is nil everywhere: model, day, window

    func testCostIsNilAtModelDayAndWindowLevelsThroughoutTheDashboardShape() async throws {
        try write([turnLine(
            eventID: "a1", secondsAgo: 1,
            models: ["grok-4.6-build": modelEntry(input: 500, output: 20, cachedRead: 100, cacheCreation: 30, ticks: 200_000_000)]
        )])
        let aggregator = await loaded()

        let usage = await lastHour(aggregator)
        XCTAssertNil(usage.breakdown.cost, "window level")
        XCTAssertNil(usage.models.first?.breakdown.cost, "per-model within the window")

        let breakdown = await aggregator.breakdown()
        XCTAssertNil(breakdown.todayTokenBreakdown.cost, "today level")
        XCTAssertNil(breakdown.byModelToday.first?.breakdown.cost, "per-model today")
        let day = try XCTUnwrap(breakdown.daily.first)
        XCTAssertNil(day.tokens.cost, "day level — the split never carries a synthesized price")

        // The dollars are real and non-zero; only the per-category split is nil, never
        // the actual number the CLI reports.
        XCTAssertGreaterThan(usage.cost, 0)
        XCTAssertGreaterThan(breakdown.todayCost, 0)
    }

    // MARK: - Headline tokens stay the CLI's own figure even when a row's total disagrees

    func testHeadlineTokenCountIsTheModelRowsOwnTotalEvenWhenItActivelyDisagreesWithInputPlusOutput() async throws {
        // The row reports input+output = 110 but a totalTokens of 999_999 — an extreme,
        // deliberately-disagreeing figure so a bug that recomputes the headline from the
        // parts instead of trusting the CLI's own total cannot pass by coincidence.
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: ["grok-4.6-build": modelEntry(input: 100, output: 10, total: 999_999, ticks: 100_000_000)]
        )])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.tokens, 999_999, "the CLI's own totalTokens is the headline, however little it agrees with the parts")
        XCTAssertEqual(usage.models.first?.tokens, 999_999)
        XCTAssertEqual(usage.breakdown.total, 110, "the split is built from input/output/cache alone")
        XCTAssertNotEqual(usage.breakdown.total, usage.tokens, "this is the whole point: they need not match")
    }

    // MARK: - Multiple models in one turn sum correctly

    func testMultipleModelsInOneTurnsPerModelBreakdownsSumToTheTurnsOwnBreakdown() async throws {
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: [
                "grok-4.6-build": modelEntry(input: 1_000, output: 50, cachedRead: 200, cacheCreation: 30, ticks: 100_000_000),
                "grok-4.3": modelEntry(input: 500, output: 25, cachedRead: 100, cacheCreation: 15, ticks: 50_000_000),
                "grok-3-mini": modelEntry(input: 250, output: 12, cachedRead: 50, cacheCreation: 5, ticks: 25_000_000),
            ]
        )])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.models.count, 3)

        let sumInput = usage.models.reduce(0) { $0 + $1.breakdown.input }
        let sumOutput = usage.models.reduce(0) { $0 + $1.breakdown.output }
        let sumCacheRead = usage.models.reduce(0) { $0 + $1.breakdown.cacheRead }
        let sumCacheWrite = usage.models.reduce(0) { $0 + $1.breakdown.cacheWrite }

        XCTAssertEqual(sumInput, usage.breakdown.input)
        XCTAssertEqual(sumOutput, usage.breakdown.output)
        XCTAssertEqual(sumCacheRead, usage.breakdown.cacheRead)
        XCTAssertEqual(sumCacheWrite, usage.breakdown.cacheWrite)

        // Expected raw numbers, computed independently of the aggregator's own code:
        // fresh input = input - cacheRead per row.
        XCTAssertEqual(usage.breakdown.input, (1_000 - 200) + (500 - 100) + (250 - 50))
        XCTAssertEqual(usage.breakdown.cacheRead, 200 + 100 + 50)
        XCTAssertEqual(usage.breakdown.output, 50 + 25 + 12)
        XCTAssertEqual(usage.breakdown.cacheWrite, 30 + 15 + 5)
    }

    // MARK: - Negative counters are clamped, not merely ignored

    func testNegativeRawCountersAreClampedToZeroNotLeftNegative() async throws {
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: [
                "grok-4.6-build": modelEntry(
                    input: -500, output: -20, cachedRead: -30, cacheCreation: -15, total: -1000, ticks: nil
                ),
            ]
        )])

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertGreaterThanOrEqual(model.breakdown.input, 0, "must not be negative")
        XCTAssertEqual(model.breakdown.input, 0)
        XCTAssertEqual(model.breakdown.output, 0)
        XCTAssertEqual(model.breakdown.cacheRead, 0)
        XCTAssertEqual(model.breakdown.cacheWrite5m, 0)
        XCTAssertEqual(model.tokens, 0, "negative totalTokens clamps to 0, and 0 falls back to input+output, also 0")
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertEqual(usage.cost, 0, "no ticks anywhere and no dynamic price loaded — the honest answer is $0, not negative")
    }

    func testANegativeCachedReadAloneDoesNotInflateFreshInputEither() async throws {
        // A negative cache-read counter clamped to 0 must not make fresh input LARGER
        // than the raw input by "subtracting a negative" before the clamp is applied.
        try write([turnLine(
            eventID: "e1", secondsAgo: 600,
            models: ["grok-4.6-build": modelEntry(input: 1_000, output: 10, cachedRead: -400, ticks: 100_000_000)]
        )])

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(model.breakdown.cacheRead, 0, "the negative counter itself clamps to zero")
        XCTAssertEqual(model.breakdown.input, 1_000, "fresh input is raw input minus a clamped (zero) cache read")
    }
}
