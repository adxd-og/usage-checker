import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Pricing
/// (report B #1): a Codex rollout ingested while the live table is empty, then priced
/// after `ModelPricing.updateDynamic`, must read exactly like a fresh aggregator
/// started with that table already in place — turns and chats both. Also covers report
/// B #6 (a truncated rollout billed once) interacting with a table arriving mid-flight.
///
/// `CodexUsageAggregatorVerificationTests.swift` already exists in this suite for an
/// unrelated, earlier spec (2026-09-05 token-breakdown design); this file is this
/// package's own, named `…Verification2Tests` per the naming convention. Fixture
/// helpers (`CodexTree`, `CodexRollout`) from `CodexRolloutFixtures.swift` are shared
/// infrastructure, not the executor's test assertions; the scenarios and numbers below
/// are independently authored.
final class CodexUsageAggregatorVerification2Tests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Verify/beta app"
    private let threadID = "02b18e92-4f7c-8d63-b5a9-6c2e0f8d4b31"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageAggregatorVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    /// Two responses in the same thread, on two different models — response 1 on
    /// "verify-model-x", response 2 on "verify-model-y". Neither is in the live table
    /// when the rollout is first read.
    private let turnIDX = "01a07d91-3e6b-7c52-a4f8-5b1d9e7c3a01"
    private let turnIDY = "01a07d91-3e6b-7c52-a4f8-5b1d9e7c3a02"

    private func writeTwoTurnChat() throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(1_800)),
            CodexRollout.turnContext(turnID: turnIDX, model: "verify-model-x", cwd: cwd, at: at(1_790)),
            CodexRollout.record(
                at: at(1_200), threadID: threadID, turnID: turnIDX, responseID: "resp_x",
                input: 2_000, cached: 0, output: 200, reasoning: 0
            ),
            CodexRollout.tokenCount(at: at(1_190), input: 2_000, cached: 0, output: 200, reasoning: 0),
            CodexRollout.turnContext(turnID: turnIDY, model: "verify-model-y", cwd: cwd, at: at(700)),
            CodexRollout.record(
                at: at(600), threadID: threadID, turnID: turnIDY, responseID: "resp_y",
                input: 500, cached: 0, output: 50, reasoning: 0
            ),
            CodexRollout.tokenCount(at: at(590), input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-2026-09-06T01-00-00-\(threadID).jsonl")
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    /// Only "verify-model-x" ever gets a live rate. "verify-model-y" stays at $0
    /// forever (no offline family match either — the id names no family word), which
    /// is a faithful read of a still-unpriceable model, not a bug: the fresh aggregator
    /// must agree exactly, one $0 turn included.
    func testAPartiallyPricedTableStillMatchesAFreshAggregatorTurnForTurn() async throws {
        try writeTwoTurnChat()
        let aggregator = tree.aggregator()
        await aggregator.refresh()

        let beforeTable = await lastHour(aggregator)
        XCTAssertEqual(beforeTable.cost, 0, accuracy: 1e-12, "nothing priced yet")
        XCTAssertEqual(beforeTable.turns, 2)

        ModelPricing.updateDynamic([
            "verify-model-x": ModelPrice(
                inputPerM: 2, outputPerM: 8, cacheReadPerM: 0.2, cacheCreate5mPerM: 0.5, cacheCreate1hPerM: 1
            )
        ])
        await aggregator.refresh()

        let fresh = tree.aggregator()
        await fresh.refresh()

        let repriced = await lastHour(aggregator)
        let control = await lastHour(fresh)
        XCTAssertEqual(repriced.turns, 2, "still exactly two turns, not doubled by the rebuild")
        XCTAssertEqual(repriced.cost, control.cost, accuracy: 1e-12)
        // response 1: 2_000 in * $2/M + 200 out * $8/M = 0.004 + 0.0016 = $0.0056; response
        // 2 stays $0 (never priced).
        XCTAssertEqual(repriced.cost, 0.0056, accuracy: 1e-12)

        let chatsRepriced = await aggregator.sessions(from: now.addingTimeInterval(-3600), to: now)
        let chatsControl = await fresh.sessions(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(chatsRepriced.count, 1)
        XCTAssertEqual(chatsControl.count, 1)
        let chat = try XCTUnwrap(chatsRepriced.first)
        let controlChat = try XCTUnwrap(chatsControl.first)
        XCTAssertEqual(chat.turns, 2, "one chat, two turns — recording again must not create a duplicate turn")
        XCTAssertEqual(chat.tokens.total, controlChat.tokens.total, "same token totals as a fresh read")
        XCTAssertEqual(chat.models.count, 2, "both models still show up in the chat's per-model rows")
        // Per-model rows stay well-defined even though the chat mixes a priced and an
        // unpriced model (the whole-chat `tokens.cost` legitimately goes nil there —
        // TokenBreakdown's `+` refuses to guess when one side has no per-category split
        // at all — so the per-model rows are the honest place to compare dollars).
        let pricedRow = try XCTUnwrap(chat.models.first { $0.model == "verify-model-x" })
        let controlPricedRow = try XCTUnwrap(controlChat.models.first { $0.model == "verify-model-x" })
        XCTAssertEqual(
            try XCTUnwrap(pricedRow.tokens.cost).total, try XCTUnwrap(controlPricedRow.tokens.cost).total,
            accuracy: 1e-12
        )
        XCTAssertEqual(try XCTUnwrap(pricedRow.tokens.cost).total, 0.0056, accuracy: 1e-12)
        let unpricedRow = try XCTUnwrap(chat.models.first { $0.model == "verify-model-y" })
        XCTAssertNil(unpricedRow.tokens.cost, "verify-model-y was never priced by anything")
    }

    /// A rollout truncated back to its first response and re-read must not add that
    /// response's tokens twice, even once a live rate makes its cost nonzero — the two
    /// mechanisms (`repriceIfTableChanged`, `restarted(after:)`) must not fight.
    func testATruncatedRolloutRereadAfterATableArrivesStillBillsEachResponseOnce() async throws {
        let url = try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(1_800)),
            CodexRollout.turnContext(model: "verify-model-x", cwd: cwd, at: at(1_790)),
            CodexRollout.record(
                at: at(1_200), threadID: threadID, responseID: "resp_x",
                input: 2_000, cached: 0, output: 200, reasoning: 0
            ),
            CodexRollout.tokenCount(at: at(1_190), input: 2_000, cached: 0, output: 200, reasoning: 0),
            CodexRollout.turnContext(model: "verify-model-x", cwd: cwd, at: at(700)),
            CodexRollout.record(
                at: at(600), threadID: threadID, responseID: "resp_y",
                input: 500, cached: 0, output: 50, reasoning: 0
            ),
            CodexRollout.tokenCount(at: at(590), input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-2026-09-06T01-00-00-\(threadID).jsonl")

        let aggregator = tree.aggregator()
        await aggregator.refresh()

        ModelPricing.updateDynamic([
            "verify-model-x": ModelPrice(
                inputPerM: 2, outputPerM: 8, cacheReadPerM: 0.2, cacheCreate5mPerM: 0.5, cacheCreate1hPerM: 1
            )
        ])

        // Rewritten shorter: only the first response survives on disk.
        try (
            [
                CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(1_800)),
                CodexRollout.turnContext(model: "verify-model-x", cwd: cwd, at: at(1_790)),
                CodexRollout.record(
                    at: at(1_200), threadID: threadID, responseID: "resp_x",
                    input: 2_000, cached: 0, output: 200, reasoning: 0
                ),
                CodexRollout.tokenCount(at: at(1_190), input: 2_000, cached: 0, output: 200, reasoning: 0),
            ].joined(separator: "\n") + "\n"
        ).write(to: url, atomically: true, encoding: .utf8)

        await aggregator.refresh()

        let after = await lastHour(aggregator)
        // Session ruling 2026-09-24 (spec § Accounting, "Codex truncated rollout"):
        // `seenResponses` survives the reset, so the re-read of the surviving
        // response adds nothing. What the spec does not promise is dropping the
        // response the shrink removed: its $0.0014 stays billed until relaunch,
        // which is the pre-existing behaviour minus the double count.
        // 2_000 in * $2/M + 200 out * $8/M = $0.0056 (resp_x, once) + $0.0014 (resp_y).
        XCTAssertEqual(after.cost, 0.0056 + 0.0014, accuracy: 1e-12, "the surviving response must not be billed twice")
        XCTAssertEqual(after.turns, 2)
    }
}
