import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Codex truncated rollout: "`seenResponses` survives a `FileState` reset; only the
/// counters are zeroed, so a re-read adds nothing twice." A rollout that shrinks is read
/// again from byte 0, and the reset used to forget which responses it had billed
/// (report B #6). The same thread in `sessions/` and `archived_sessions/` at two lengths
/// shrinks on every poll.
final class CodexTruncatedRolloutTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// Anchored at least an hour into the local day, like the other Codex suites.
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let threadID = "01a07c3e-5d2f-7a41-8b69-3c7f9b5e2d01"

    private var fileName: String { "rollout-2026-09-06T02-09-23-\(threadID).jsonl" }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTruncatedRolloutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
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

    /// Two responses, each a record and the cumulative counter that restates it — the
    /// shape a current CLI writes.
    private func twoResponses() -> [String] {
        [
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(at: at(600), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.tokenCount(at: at(590), input: 1_000, cached: 400, output: 100, reasoning: 30),
            CodexRollout.record(at: at(300), threadID: threadID, responseID: "resp_b",
                                input: 1_500, cached: 700, output: 120, reasoning: 40),
            CodexRollout.tokenCount(at: at(290), input: 2_500, cached: 1_100, output: 220, reasoning: 70),
        ]
    }

    /// The same file cut after the first response: byte-for-byte the first four lines.
    private func firstResponseOnly() -> [String] { Array(twoResponses().prefix(4)) }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    func testARolloutRewrittenShorterBillsNothingTwice() async throws {
        try tree.writeRollout(twoResponses(), named: fileName)
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        let before = await lastHour(aggregator)
        XCTAssertEqual(before.turns, 2)

        try tree.writeRollout(firstResponseOnly(), named: fileName)
        await aggregator.refresh()

        let after = await lastHour(aggregator)
        XCTAssertEqual(after.turns, 2, "resp_a is not billed a second time; resp_b, already billed, stays")
        XCTAssertEqual(after.tokens, before.tokens)
        XCTAssertEqual(after.cost, before.cost, accuracy: 1e-12)
    }

    func testALongerAndAShorterCopyOfOneThreadBillEachResponseOnce() async throws {
        try tree.writeRollout(twoResponses(), named: fileName)
        try tree.writeArchived(firstResponseOnly(), named: fileName)
        let aggregator = tree.aggregator()

        for poll in 1...3 {
            await aggregator.refresh()
            let usage = await lastHour(aggregator)
            XCTAssertEqual(usage.turns, 2, "poll \(poll): two responses, however the copies alternate")
            XCTAssertEqual(usage.tokens, 2_720, "poll \(poll): 1_100 + 1_620")
        }
    }
}
