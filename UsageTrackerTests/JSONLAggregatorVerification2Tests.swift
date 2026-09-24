import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting:
/// Pricing (report B #1) — a Claude turn priced by a family guess is priced again once
/// the live table names its model; a turn priced by an exact offline row is never
/// touched by a generation bump. Time zone (report B #3) — a day folded in one zone and
/// reloaded in another lands on the new zone's midnight and reaches the Activity grid.
///
/// `JSONLAggregatorVerificationTests.swift` already exists in this suite for an
/// unrelated, earlier spec (token-breakdown design); this file is this package's own,
/// named `…Verification2Tests`. The transcript shape is the one Claude Code writes on
/// this Mac (see `JSONLDeferredFoldTests`), authored independently with its own ids,
/// models and timestamps.
final class JSONLAggregatorVerification2Tests: XCTestCase {
    private var root: URL!
    private let slug = "-Users-verifier2-Projects-gamma"

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func plus3Calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLAggregatorVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
        ModelPricing.updateDynamic([:])
    }

    private var cacheURL: URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-verify2-cache.json")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// One final `type: assistant` line, real Claude Code 2.1.280 shape (ids/paths
    /// scrubbed), `input`/`output` tokens and model swappable per call.
    private func record(
        id: String, model: String, at date: Date, input: Int = 1_000_000, output: Int = 200_000,
        sessionID: String
    ) -> String {
        let ts = Self.iso.string(from: date)
        return """
        {"parentUuid":"5b1c7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"container":null,"stop_reason":"end_turn",\
        "stop_sequence":null,"stop_details":null,"usage":{"input_tokens":\(input),\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,\
        "output_tokens":\(output),"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfVerify2Request00000",\
        "type":"assistant","uuid":"9e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(ts)","effort":"xhigh","perTurnEffort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/gamma",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"verify-two-crown"}
        """
    }

    private func writeTranscript(_ lines: [String], sessionID: String) throws {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func lastDay(_ aggregator: JSONLAggregator, now: Date) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-86_400), to: now)
    }

    // MARK: - Pricing

    func testAFamilyGuessedTurnMovesToTheLiveRateOnceTheTableNamesTheModel() async throws {
        let now = Date()
        let unnamedSonnet = "claude-sonnet-9-preview"
        try writeTranscript(
            [record(id: "msg_verify2_A", model: unnamedSonnet, at: now.addingTimeInterval(-600), sessionID: "sess-verify2-a")],
            sessionID: "sess-verify2-a"
        )
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utcCalendar())
        await aggregator.refresh()

        let guessed = await lastDay(aggregator, now: now)
        // No exact/live row for "claude-sonnet-9-preview": family fallback to
        // claude-sonnet-4-6 ($3/$15). 1M in * $3 + 200k out * $15/M = $3 + $3 = $6.
        XCTAssertEqual(guessed.cost, 6, accuracy: 1e-9, "priced at the sonnet family's rate")

        ModelPricing.updateDynamic([unnamedSonnet: ModelPrice(
            inputPerM: 2, outputPerM: 10, cacheReadPerM: 0.2, cacheCreate5mPerM: 0.5, cacheCreate1hPerM: 1
        )])
        await aggregator.refresh()

        let repriced = await lastDay(aggregator, now: now)
        // 1M * $2/M + 200k * $10/M = $2 + $2 = $4.
        XCTAssertEqual(repriced.cost, 4, accuracy: 1e-9, "now priced at its own live rate, not the family's")
    }

    func testATurnPricedByAnExactOfflineRowIsUntouchedByAGenerationBumpForAnUnrelatedModel() async throws {
        let now = Date()
        let namedModel = "claude-sonnet-4-6"
        try writeTranscript(
            [record(id: "msg_verify2_B", model: namedModel, at: now.addingTimeInterval(-600), sessionID: "sess-verify2-b")],
            sessionID: "sess-verify2-b"
        )
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utcCalendar())
        await aggregator.refresh()

        let before = await lastDay(aggregator, now: now)
        // Exact offline row: $3/$15. 1M in + 200k out = $3 + $3 = $6.
        XCTAssertEqual(before.cost, 6, accuracy: 1e-9)

        // Bump the generation via an entirely unrelated model.
        ModelPricing.updateDynamic(["some-other-model-verify2": ModelPrice(
            inputPerM: 999, outputPerM: 999, cacheReadPerM: 999, cacheCreate5mPerM: 999, cacheCreate1hPerM: 999
        )])
        await aggregator.refresh()

        let after = await lastDay(aggregator, now: now)
        XCTAssertEqual(after.cost, before.cost, accuracy: 1e-15, "an exact-row turn is never re-priced")
        XCTAssertEqual(after.cost, 6, accuracy: 1e-9)
    }

    // MARK: - Time zone

    /// A turn 40 days before `now` (well past the 31-day recent window) is folded into
    /// `oldDays` by a UTC-calendar aggregator, flushed to disk, then loaded by a second
    /// aggregator running under UTC+3. The reloaded day must land on UTC+3's midnight of
    /// the SAME calendar date and reach `GridCache` so the Activity square for that date
    /// is filled — not silently dropped while the 30/90/365 cards still counted it.
    func testADayFoldedInUTCAndReloadedUnderUTCPlus3FillsTheActivitySquare() async throws {
        let now = Date()
        let utc = utcCalendar()
        let plus3 = plus3Calendar()
        // 40 days back, 08:00 UTC — inside the fold window, well clear of both
        // midnights so the "noon-anchored" rekey rule is exercised honestly.
        let oldDay = utc.date(byAdding: .day, value: -40, to: utc.startOfDay(for: now))!
        let turnAt = utc.date(byAdding: .hour, value: 8, to: oldDay)!

        try writeTranscript(
            [record(id: "msg_verify2_Old", model: "claude-sonnet-4-6", at: turnAt, input: 500_000, output: 100_000, sessionID: "sess-verify2-old")],
            sessionID: "sess-verify2-old"
        )

        let folded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await folded.refresh()
        await folded.flushCache()

        let expectedUTCDay = utc.startOfDay(for: turnAt)
        let expectedPlus3Day = plus3.startOfDay(for: expectedUTCDay.addingTimeInterval(12 * 3600))
        // Sanity: the two midnights really are different instants — otherwise the test
        // would pass trivially with no zone change actually exercised.
        XCTAssertNotEqual(expectedUTCDay, expectedPlus3Day)

        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: plus3)
        await reloaded.refresh()

        let daily = await reloaded.breakdown().daily
        let landedDay = try XCTUnwrap(
            daily.first { $0.day == expectedPlus3Day },
            "the folded day must land on UTC+3's midnight of the same date, not go missing"
        )
        // 500_000 in * $3/M + 100_000 out * $15/M = $1.5 + $1.5 = $3.
        XCTAssertEqual(landedDay.totalCost, 3, accuracy: 1e-9)

        let grid = GridCache.build(from: daily, weeks: 12, now: now, calendar: plus3)
        let squareValue = try XCTUnwrap(
            grid.value(on: expectedPlus3Day), "the Activity square for that date must have a reading"
        )
        XCTAssertEqual(squareValue, 3, accuracy: 1e-9, "the Activity square for that date is filled")
    }
}
