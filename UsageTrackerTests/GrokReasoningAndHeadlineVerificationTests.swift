import XCTest
@testable import Omelette

/// Independent verification of commit e924c02 ("Grok: read reasoningTokens, and take
/// the headline from the turn's own total"). Written without reading
/// `GrokUsageAggregatorTests`; focuses on three things the spec calls out explicitly:
/// `reasoningTokens` is reported into `thinking` with no clamp against `outputTokens`
/// (pinning the actual, unclamped behaviour rather than asserting a rule the code
/// doesn't implement), a wholly absent `totalTokens` key behaves like an explicit zero
/// (falls back to the model rows), and the outer total winning for the headline while
/// the breakdown still keeps the per-model parts when the two disagree.
final class GrokReasoningAndHeadlineVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokReasoningAndHeadlineVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    /// One `turn_completed` JSON-RPC line, shaped like a real Grok CLI `updates.jsonl`
    /// entry. `outerTotalTokens: nil` omits the key from the outer `usage` object
    /// entirely (distinct from writing an explicit 0).
    private func turnLine(
        eventID: String, secondsAgo: Double,
        outerInput: Int, outerOutput: Int, outerTotalTokens: Int?,
        modelInput: Int, modelOutput: Int, modelCachedRead: Int = 0,
        modelReasoning: Int = 0, ticks: Int = 100_000_000,
        model: String = "grok-4.6-build"
    ) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        let outerTotalField = outerTotalTokens.map { ",\"totalTokens\":\($0)" } ?? ""
        let modelTotal = modelInput + modelOutput
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"s",\
        "update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":\(outerInput),\
        "outputTokens":\(outerOutput)\(outerTotalField),"cachedReadTokens":0,"cacheCreationTokens":0,\
        "costUsdTicks":\(ticks),"modelUsage":{"\(model)":{"inputTokens":\(modelInput),\
        "outputTokens":\(modelOutput),"totalTokens":\(modelTotal),"cachedReadTokens":\(modelCachedRead),\
        "reasoningTokens":\(modelReasoning),"costUsdTicks":\(ticks)}}}},\
        "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    private func write(_ lines: [String], project: String = "%2Ftmp%2FGrokVerify", session: String = "session-uuid") throws {
        let dir = root
            .appendingPathComponent(project, isDirectory: true)
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

    // MARK: - Reasoning tokens: unclamped, never widens the total

    func testReasoningTokensExceedingOutputAreReportedAsIsWithNoClamp() async throws {
        // A nonsensical but possible log line: reasoningTokens (999) larger than
        // outputTokens (50) for the same row. The production code applies no clamp
        // against output — this pins that actual behaviour rather than inventing a
        // rule the implementation doesn't have.
        try write([turnLine(
            eventID: "e-big-reasoning", secondsAgo: 600,
            outerInput: 1_000, outerOutput: 50, outerTotalTokens: 1_050,
            modelInput: 1_000, modelOutput: 50, modelReasoning: 999
        )])

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(model.breakdown.thinking, 999, "recorded as-is, not clamped to the output count")
        XCTAssertEqual(model.breakdown.output, 50, "output itself is untouched")
        XCTAssertEqual(model.breakdown.total, 1_050, "thinking never joins the total, however large")
        XCTAssertEqual(usage.tokens, 1_050)
    }

    // MARK: - Outer totalTokens: absent key vs. explicit zero vs. disagreement

    func testAWhollyAbsentOuterTotalTokensKeyFallsBackToTheModelRowsSum() async throws {
        // Not "totalTokens": 0 — the key is not present in the JSON at all. The parser
        // must treat a missing field the same as zero and fall back to the rows.
        try write([turnLine(
            eventID: "e-no-total-key", secondsAgo: 600,
            outerInput: 700, outerOutput: 30, outerTotalTokens: nil,
            modelInput: 700, modelOutput: 30
        )])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "an absent field is not a parse failure")
        XCTAssertEqual(usage.tokens, 730, "falls back to the one model row's own total (700 + 30)")
    }

    func testTheOuterTotalWinsForTheHeadlineButTheBreakdownKeepsOnlyTheModelRows() async throws {
        // The CLI can bill a model call its `modelUsage` map never breaks out, so the
        // outer total (9_999) is deliberately far from what the one named row adds to
        // (110). The headline must read the outer figure; the breakdown, built only
        // from what was actually itemized, must not inflate to match it.
        try write([turnLine(
            eventID: "e-disagree", secondsAgo: 600,
            outerInput: 9_000, outerOutput: 999, outerTotalTokens: 9_999,
            modelInput: 100, modelOutput: 10
        )])

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.tokens, 9_999, "the outer total is the headline")
        XCTAssertEqual(usage.breakdown.total, 110, "the breakdown only knows what the row itemized")
        XCTAssertEqual(usage.models.first?.tokens, 110, "the per-model row keeps its own count too")
    }
}
