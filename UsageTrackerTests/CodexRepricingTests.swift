import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Pricing: when the live price table changes, the Codex turns of the last 31 days —
/// and the chats lying wholly inside that window — are priced again from the tokens
/// and the model each turn kept. A model models.dev did not know at the first scan
/// read $0 until a relaunch. models.dev never loads in this target: the tests move
/// the table themselves and clear it in teardown.
final class CodexRepricingTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// Anchored at least an hour into the local day, like the other Codex suites.
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let threadID = "01a07d91-3e6b-7c52-a4f8-5b1d9e7c3a20"
    /// "gpt-5.6-terra" resolves to this row through `dynamicLookup`'s suffix strip.
    private let terra = ModelPrice(
        inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
        cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRepricingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    /// One response as a current CLI writes it — the record, then the counter that
    /// restates it: 1_000 in (400 of it cached), 100 out. $0.0018 at `terra`.
    private func writeOneResponse() throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(at: at(600), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.tokenCount(at: at(590), input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-06T02-09-23-\(threadID).jsonl")
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    func testATurnReadBeforeTheTableKnewItsModelIsPricedOnceTheTableDoes() async throws {
        try writeOneResponse()
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        let unpriced = await lastHour(aggregator)
        XCTAssertEqual(unpriced.cost, 0, accuracy: 1e-12, "no rate yet: $0, the tokens kept")
        XCTAssertNil(unpriced.breakdown.cost)
        XCTAssertEqual(unpriced.tokens, 1_100)

        ModelPricing.updateDynamic(["gpt-5.6": terra])
        await aggregator.refresh()

        let priced = await lastHour(aggregator)
        XCTAssertEqual(priced.cost, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(priced.breakdown.cost).total, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(priced.tokens, 1_100, "the tokens themselves do not move")
        let week = await aggregator.costs(now: now).week
        XCTAssertEqual(week, 0.0018, accuracy: 1e-12)
    }

    /// The report's own check: after the table lands, the running aggregator reads
    /// exactly like one started fresh with the table already there.
    func testARepricedWindowReadsLikeAFreshStart() async throws {
        try writeOneResponse()
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        ModelPricing.updateDynamic(["gpt-5.6": terra])
        await aggregator.refresh()

        let fresh = tree.aggregator()
        await fresh.refresh()

        let repriced = await aggregator.breakdown()
        let control = await fresh.breakdown()
        XCTAssertEqual(repriced.weekCost, control.weekCost, accuracy: 1e-12)
        XCTAssertEqual(repriced.monthCost, control.monthCost, accuracy: 1e-12)
        XCTAssertEqual(repriced.daily.map(\.totalCost), control.daily.map(\.totalCost))
        XCTAssertEqual(repriced.daily.map(\.tokens), control.daily.map(\.tokens))
    }

    /// Codex keeps nothing on disk: a relaunch prices every turn at today's table, so
    /// the running app does too — a moved rate moves a turn the old one had priced.
    func testANewRateMovesATurnTheOldRateHadPriced() async throws {
        ModelPricing.updateDynamic(["gpt-5.6": terra])
        try writeOneResponse()
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        let before = await lastHour(aggregator)
        XCTAssertEqual(before.cost, 0.0018, accuracy: 1e-12)

        ModelPricing.updateDynamic(["gpt-5.6": ModelPrice(
            inputPerM: 2.5, outputPerM: 20, cacheReadPerM: 0.25,
            cacheCreate5mPerM: 3.125, cacheCreate1hPerM: 5
        )])
        await aggregator.refresh()

        let after = await lastHour(aggregator)
        XCTAssertEqual(after.cost, 0.0036, accuracy: 1e-12, "every rate doubled")
    }

    func testAChatInsideTheWindowTakesTheNewDollars() async throws {
        try writeOneResponse()
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        ModelPricing.updateDynamic(["gpt-5.6": terra])
        await aggregator.refresh()

        let chats = await aggregator.sessions(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(chats.count, 1)
        let chat = try XCTUnwrap(chats.first)
        XCTAssertEqual(chat.turns, 1, "recorded again, not recorded twice")
        XCTAssertEqual(chat.tokens.total, 1_100)
        XCTAssertEqual(try XCTUnwrap(chat.tokens.cost).total, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(chat.models.first?.tokens.cost).total, 0.0018, accuracy: 1e-12)
    }
}
