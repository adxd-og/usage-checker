import XCTest
@testable import Omelette

/// The billing switch of spec § 3: a rollout that writes `token_usage_record` lines is
/// billed from them, and its cumulative `token_count` keeps only the baseline. Verified
/// against this Mac's 2026-09-06 17:25 rollout, where the records sum to 3,783,861 and
/// `token_count` ends at 3,523,616 — the 260,245 difference is one compaction response
/// the counter never sees.
///
/// models.dev never loads in this target, so the rates the dollar assertions are
/// computed from are seeded into `ModelPricing.updateDynamic` and cleared in teardown.
final class CodexRecordBillingTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// Anchored at least an hour into the local day: fixtures are stamped up to fifteen
    /// minutes back, and a suite that ran just after midnight would file them under
    /// yesterday and read zero for "today".
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let threadID = "01a0771c-8238-75f0-bb53-0191ef8f612e"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRecordBillingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        // `dynamicLookup` strips variant suffixes, so "gpt-5.6-terra" resolves to this
        // row. OpenAI bills cache writes from GPT-5.6 on at 1.25x the uncached input
        // rate, so the 5m rate here is 1.25 x 1.25.
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - The switch

    func testARecordBillsTheResponseAndTheTokenCountThatRestatesItAddsNothing() async throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, effort: "xhigh", cwd: cwd, at: at(890)),
            CodexRollout.record(
                at: at(600), threadID: threadID, responseID: "resp_a",
                input: 1_000, cached: 400, output: 100, reasoning: 30
            ),
            // The same response, restated by the cumulative counter one line later.
            CodexRollout.tokenCount(at: at(590), input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-a.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "one response, billed once — by the record")
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.breakdown.input, 600, "1_000 − 400 cached − 0 written")
        XCTAssertEqual(usage.breakdown.cacheRead, 400)
        XCTAssertEqual(usage.breakdown.output, 100)
        XCTAssertEqual(usage.breakdown.thinking, 30)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testAFileThatSwitchesFromCountersToRecordsBillsEachResponseExactlyOnce() async throws {
        // Some 0.153.0 rollouts start on counters and only later write records, so the
        // rule is per file and per position, not per version: the two responses the
        // counter described are billed from its deltas, the third from its record, and
        // the counter that follows the record adds nothing.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.tokenCount(at: at(800), input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.tokenCount(at: at(700), input: 3_000, cached: 1_400, cacheWrite: 200,
                                    output: 300, reasoning: 90),
            CodexRollout.record(
                at: at(600), threadID: threadID, responseID: "resp_c",
                input: 1_500, cached: 700, output: 120, reasoning: 40
            ),
            CodexRollout.tokenCount(at: at(590), input: 4_500, cached: 2_100, cacheWrite: 200,
                                    output: 420, reasoning: 130),
        ], named: "rollout-switch.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 3)
        let b = usage.breakdown
        XCTAssertEqual(b.input, 2_200, "600 + 800 + 800")
        XCTAssertEqual(b.cacheRead, 2_100, "400 + 1_000 + 700")
        XCTAssertEqual(b.cacheWrite5m, 200)
        XCTAssertEqual(b.output, 420)
        XCTAssertEqual(b.thinking, 130)
        XCTAssertEqual(b.total, 4_920)
        XCTAssertEqual(usage.tokens, 4_920)
        XCTAssertEqual(usage.cost, 0.007525, accuracy: 1e-12)
    }

    func testTheCompactionCallIsBilledAndTheCopyInsideTheCompactedRecordIsNot() async throws {
        // The numbers are the 09-06 17:25 rollout's own compaction response
        // (resp_…e1157e6b): a top-level record, then a `compacted` line whose
        // `latest_token_usage_record` repeats it verbatim.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(
                at: at(700), threadID: threadID, responseID: "resp_a",
                input: 1_000, cached: 400, output: 100, reasoning: 30
            ),
            CodexRollout.tokenCount(at: at(690), input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.record(
                at: at(600), threadID: threadID, responseID: "resp_compact",
                input: 252_258, cached: 244_608, output: 7_987, reasoning: 0
            ),
            CodexRollout.compacted(
                at: at(599), threadID: threadID, responseID: "resp_compact",
                input: 252_258, cached: 244_608, output: 7_987, reasoning: 0
            ),
            // The counter never grew for the compaction call — that is the whole bug.
            CodexRollout.tokenCount(at: at(590), input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-compaction.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "the ordinary response and the compaction call")
        XCTAssertEqual(usage.tokens, 261_345, "1_100 + 260_245")
        XCTAssertEqual(usage.breakdown.input, 8_250, "600 + 7_650")
        XCTAssertEqual(usage.breakdown.cacheRead, 245_008)
        XCTAssertEqual(usage.breakdown.output, 8_087)
        XCTAssertEqual(usage.cost, 0.1218085, accuracy: 1e-9)
    }

    func testTheSameResponseIsBilledOnceHoweverOftenItsRecordIsWritten() async throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(at: at(700), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.record(at: at(650), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.record(at: at(600), threadID: threadID, responseID: "resp_b",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-dupe.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "two response ids, however many lines describe them")
        XCTAssertEqual(usage.tokens, 2_200)
    }

    func testATokenCountWithNullInfoIsSkippedAndLeavesTheBaselineAlone() async throws {
        // A counters-only file: `info: null` carries no counters, so it must neither
        // bill nor reset the baseline the next real reading is measured against.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.tokenCount(at: at(700), input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.nullInfoTokenCount(at: at(650)),
            CodexRollout.tokenCount(at: at(600), input: 3_000, cached: 1_400, output: 300, reasoning: 90),
        ], named: "rollout-nullinfo.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2)
        // The first reading is its own delta (1_000 − 400 cached); the second's delta is
        // 2_000 input against 1_000 newly cached.
        XCTAssertEqual(usage.breakdown.input, 600 + 1_000)
        XCTAssertEqual(usage.tokens, 1_100 + 2_200)
    }

    // MARK: - Model and effort for a record

    func testTheModelComesFromTheTurnContextWithTheSameTurnIDNotTheLatestOne() async throws {
        // A record names the turn it belongs to. Billing it at the *latest* context
        // would price this response with a model that has no rates at all, and the
        // dollars would silently drop to zero.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(turnID: "turn-1", model: model, effort: "xhigh",
                                     cwd: cwd, at: at(890)),
            CodexRollout.turnContext(turnID: "turn-2", model: "no-such-model-xyz",
                                     effort: "low", cwd: cwd, at: at(700)),
            CodexRollout.record(at: at(600), threadID: threadID, turnID: "turn-1",
                                responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-turnid.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.models.map(\.model), ["GPT 5.6 Terra"])
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testARecordWhoseTurnIDNamesNoContextFallsBackToTheLatestOne() async throws {
        // Real sub-agent rollouts carry a `turn_context` for the parent's root turn
        // before their own, so a record can legitimately name a turn this file has no
        // context for. The tokens are real; the latest context is the best label.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(turnID: "turn-1", model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(at: at(600), threadID: threadID, turnID: "turn-unknown",
                                responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-fallback.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testTheContextRulePrefersTheExactTurnAndFallsBackToTheLatest() {
        let one = CodexUsageAggregator.TurnContext(model: "a", effort: "high")
        let two = CodexUsageAggregator.TurnContext(model: "b", effort: "low")
        let contexts = ["turn-1": one, "turn-2": two]

        XCTAssertEqual(CodexUsageAggregator.context(forTurn: "turn-1", in: contexts, latest: two), one)
        XCTAssertEqual(CodexUsageAggregator.context(forTurn: "turn-9", in: contexts, latest: two), two)
        XCTAssertEqual(CodexUsageAggregator.context(forTurn: nil, in: contexts, latest: two), two)
        XCTAssertNil(CodexUsageAggregator.context(forTurn: "turn-9", in: contexts, latest: nil))
    }

    func testARecordBeforeAnyTurnContextWaitsForTheModelThatFollows() async throws {
        // The same recovery the counter path already has: tokens with nothing to price
        // or label them wait in the file's state instead of being dropped.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.record(at: at(700), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(600)),
        ], named: "rollout-early-record.jsonl")

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }
}
