import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Pricing
/// (report B #1): "table-priced turns follow a price table that arrives late" — a
/// slice the CLI itself priced (`costUsdTicks`) must never move when the live table
/// changes; a slice with no `costUsdTicks` anywhere in the turn is priced from the
/// table once it arrives.
///
/// `GrokUsageAggregatorVerificationTests.swift` already exists in this suite for an
/// unrelated, earlier spec (token-breakdown design); this file is this package's own,
/// named `…Verification2Tests`. The JSON shape is written independently (own field
/// ordering and helper), matching `~/.grok/sessions/<percent-encoded-cwd>/<uuid>/
/// updates.jsonl`'s `_x.ai/session/update` / `turn_completed` envelope.
final class GrokUsageAggregatorVerification2Tests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let projectDir = "%2Ftmp%2FGrok%20Verify%202%2Fgamma"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokUsageAggregatorVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    /// A turn whose own model row carries `costUsdTicks` — the CLI's own dollars.
    private func tickedTurnLine(secondsAgo: Double, eventID: String) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"verify-sess-1",\
        "update":{"sessionUpdate":"turn_completed","prompt_id":"p1","stop_reason":"end_turn",\
        "usage":{"inputTokens":10000,"outputTokens":100,"totalTokens":10100,\
        "cachedReadTokens":0,"cacheCreationTokens":0,"costUsdTicks":200000000,\
        "modelUsage":{"grok-verify-ticked":{"inputTokens":10000,"outputTokens":100,\
        "totalTokens":10100,"cachedReadTokens":0,"cacheCreationTokens":0,\
        "costUsdTicks":200000000,"modelCalls":1,"apiDurationMs":50}},\
        "modelCalls":1,"apiDurationMs":50,"numTurns":1}},\
        "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    /// A turn with no `costUsdTicks` anywhere — neither on the turn nor on its one
    /// model row — the shape a CLI build predating the field writes.
    private func untickedTurnLine(secondsAgo: Double, eventID: String) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"verify-sess-1",\
        "update":{"sessionUpdate":"turn_completed","prompt_id":"p2","stop_reason":"end_turn",\
        "usage":{"inputTokens":4000,"outputTokens":40,"totalTokens":4040,\
        "cachedReadTokens":0,"cacheCreationTokens":0,\
        "modelUsage":{"grok-verify-unticked":{"inputTokens":4000,"outputTokens":40,\
        "totalTokens":4040,"cachedReadTokens":0,"cacheCreationTokens":0,\
        "modelCalls":1,"apiDurationMs":50}},\
        "modelCalls":1,"apiDurationMs":50,"numTurns":1}},\
        "_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    private func write(_ lines: [String]) throws {
        let dir = root.appendingPathComponent(projectDir, isDirectory: true)
            .appendingPathComponent("verify-session-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
    }

    private func lastHour(_ aggregator: GrokUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    func testATickedSliceHoldsItsExactDollarsAcrossATableArrivalAndAGenerationBump() async throws {
        try write([
            tickedTurnLine(secondsAgo: 600, eventID: "verify-ticked-1"),
            untickedTurnLine(secondsAgo: 500, eventID: "verify-unticked-1"),
        ])
        let aggregator = GrokUsageAggregator(rootURL: root)
        await aggregator.refresh()

        let before = await lastHour(aggregator)
        // 200_000_000 ticks / 1e10 = $0.02 for the ticked turn; the unticked turn is $0
        // with no live table at all.
        XCTAssertEqual(before.cost, 0.02, accuracy: 1e-12)

        ModelPricing.updateDynamic([
            "grok-verify-unticked": ModelPrice(
                inputPerM: 5, outputPerM: 20, cacheReadPerM: 0.5, cacheCreate5mPerM: 1, cacheCreate1hPerM: 2
            ),
            // Deliberately also seed a (wrong, unrealistic) rate for the TICKED model.
            // If the ticked slice ever fell back to table pricing this would move its
            // cost far off $0.02 and the test would catch it.
            "grok-verify-ticked": ModelPrice(
                inputPerM: 999, outputPerM: 999, cacheReadPerM: 999, cacheCreate5mPerM: 999, cacheCreate1hPerM: 999
            ),
        ])
        await aggregator.refresh()

        let after = await lastHour(aggregator)
        // Unticked: 4_000 in * $5/M + 40 out * $20/M = 0.02 + 0.0008 = $0.0208.
        // Ticked stays $0.02 exactly.
        XCTAssertEqual(after.cost, 0.02 + 0.0208, accuracy: 1e-12)

        // Isolate the ticked turn alone to check it bit-for-bit: a narrower window than
        // "last hour" that only the ticked line falls inside.
        let tickedOnly = await aggregator.usage(
            from: now.addingTimeInterval(-620), to: now.addingTimeInterval(-550)
        )
        XCTAssertEqual(tickedOnly.turns, 1)
        XCTAssertEqual(tickedOnly.cost, 0.02, accuracy: 1e-12, "the CLI's own dollars, untouched by any table")
    }

    func testAnUntickedSliceStaysAtZeroWithNoTableAndOnlyMovesOnceOneArrives() async throws {
        try write([untickedTurnLine(secondsAgo: 300, eventID: "verify-unticked-solo")])
        let aggregator = GrokUsageAggregator(rootURL: root)
        await aggregator.refresh()

        let before = await lastHour(aggregator)
        XCTAssertEqual(before.cost, 0, accuracy: 1e-12, "no CLI dollars and no table yet: the tokens count, not $0-as-priced")
        XCTAssertEqual(before.turns, 1)

        ModelPricing.updateDynamic([
            "grok-verify-unticked": ModelPrice(
                inputPerM: 2, outputPerM: 10, cacheReadPerM: 0.2, cacheCreate5mPerM: 0.5, cacheCreate1hPerM: 1
            )
        ])
        await aggregator.refresh()

        let after = await lastHour(aggregator)
        // 4_000 in * $2/M + 40 out * $10/M = 0.008 + 0.0004 = $0.0084.
        XCTAssertEqual(after.cost, 0.0084, accuracy: 1e-12)
    }
}
