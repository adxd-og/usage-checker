import XCTest
@testable import Omelette

/// Independent verification of `JSONLAggregator`'s token-breakdown wiring, written
/// without reading `JSONLAggregatorTests`. Covers: a fixture copied from this machine's
/// real `~/.claude/projects/*/*.jsonl` usage shape (own numbers), `thinking_tokens` as a
/// JSON literal `null` and as a wholly absent key, triple-duplicated message ids,
/// id-less-line dedup identity, the old-day fold path exercised directly (not only
/// through a cache round trip), byModelToday summing to the day total, window exclusion,
/// and the cache's v1 rejection / v2 round trip / foreign-root rejection.
final class JSONLAggregatorVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let slug = "-Users-verifier-Projects-checked"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLAggregatorVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private var cacheURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-cache.json")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func write(_ lines: [String], project: String = "", file: String = "session.jsonl") throws {
        let dir = root.appendingPathComponent(project.isEmpty ? slug : project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, project: String, file: String = "session.jsonl") throws {
        let url = root.appendingPathComponent(project, isDirectory: true).appendingPathComponent(file)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - A real-shaped line, own numbers

    /// Copied field-for-field from a `type: assistant` line in
    /// `~/.claude/projects/-Users-andreianiukov-Desktop-Jaravis/a127ceed-dd01-41c8-8560-b159f317b362.jsonl`
    /// (verified 2026-09-05: `cache_creation_input_tokens`, `output_tokens_details`,
    /// `server_tool_use`, `service_tier`, nested `cache_creation`, `inference_geo`, and
    /// an `iterations` array all appear alongside the fields the parser actually reads),
    /// with this test's own token counts substituted in and both cache TTLs non-zero.
    private func realShapedLine(id: String, minutesAgo: Double, thinking: Int) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1234567,"cache_creation_input_tokens":52467,\
        "cache_read_input_tokens":345678,"output_tokens":234567,\
        "output_tokens_details":{"thinking_tokens":\(thinking)},\
        "server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},\
        "service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":6789,"ephemeral_5m_input_tokens":45678},\
        "inference_geo":"not_available",\
        "iterations":[{"input_tokens":1234567,"output_tokens":234567,\
        "cache_read_input_tokens":345678,"cache_creation_input_tokens":52467,\
        "cache_creation":{"ephemeral_5m_input_tokens":45678,"ephemeral_1h_input_tokens":6789},\
        "type":"message"}],"speed":"standard"}}}
        """
    }

    func testARealShapedLineParsesTheFullSplitWithBothCacheTTLsNonZero() async throws {
        try write([realShapedLine(id: "msg_real", minutesAgo: 5, thinking: 98_765)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.input, 1_234_567)
        XCTAssertEqual(usage.breakdown.output, 234_567)
        XCTAssertEqual(usage.breakdown.cacheRead, 345_678)
        XCTAssertEqual(usage.breakdown.cacheWrite5m, 45_678)
        XCTAssertEqual(usage.breakdown.cacheWrite1h, 6_789)
        XCTAssertEqual(usage.breakdown.cacheWrite, 52_467, "the top-level cache_creation_input_tokens the log also carries")
        XCTAssertEqual(usage.breakdown.thinking, 98_765)
        let expectedTotal = 1_234_567 + 234_567 + 345_678 + 45_678 + 6_789
        XCTAssertEqual(usage.breakdown.total, expectedTotal)
        XCTAssertEqual(usage.tokens, expectedTotal, "Claude's headline is the parts' sum")
        XCTAssertEqual(try XCTUnwrap(usage.breakdown.cost).total, usage.cost, accuracy: 1e-9)
    }

    // MARK: - thinking_tokens: present / absent / JSON null

    func testThinkingTokensAsExplicitJSONNullDefaultsToZeroRatherThanDroppingTheLine() async throws {
        let ts = Self.iso.string(from: now.addingTimeInterval(-600))
        let raw = """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg_null_thinking","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens_details":{"thinking_tokens":null}}}}
        """
        try write([raw])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1, "a JSON null in thinking_tokens must not drop the whole turn")
        XCTAssertEqual(usage.breakdown.thinking, 0)
        XCTAssertEqual(usage.breakdown.input, 1000)
    }

    func testThinkingTokensWithNoOutputTokensDetailsKeyAtAllDefaultsToZero() async throws {
        let ts = Self.iso.string(from: now.addingTimeInterval(-600))
        let raw = """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg_no_details","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
        try write([raw])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.thinking, 0)
        XCTAssertEqual(usage.breakdown.total, 1200)
    }

    // MARK: - Dedup identity

    func testAMessageIdRepeatedThreeTimesCountsOnce() async throws {
        // Claude Code can log the same response several times across a session's life
        // (a tail re-scan, a forked replay); three is a real multiplicity, not just two.
        let line = realShapedLine(id: "msg_triple", minutesAgo: 10, thinking: 0)
        try write([line, line, line])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1, "three identical message ids in the log are one turn")
    }

    private func idlessLine(input: Int, output: Int, thinking: Int, minutesAgo: Double) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens_details":{"thinking_tokens":\(thinking)}}}}
        """
    }

    func testIdlessLinesIdenticalInEveryFieldIncludingThinkingDedupeToOneTurn() async throws {
        // The complement of "differ only in thinking → two turns": truly identical
        // content, thinking included, must fold to a single turn — the fallback key is
        // content identity, not a per-line nonce.
        let a = idlessLine(input: 2_000_000, output: 300_000, thinking: 40_000, minutesAgo: 12)
        try write([a, a])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1, "byte-identical id-less lines, thinking included, are one turn")
        XCTAssertEqual(usage.breakdown.input, 2_000_000)
    }

    func testIdlessLinesDifferingOnlyInCacheReadAreTwoTurns() async throws {
        // A second axis of the same claim as thinking: any field difference in the
        // content-derived key must produce two turns, not just a thinking difference.
        let ts = Self.iso.string(from: now.addingTimeInterval(-600))
        func line(cacheRead: Int) -> String {
            """
            {"type":"assistant","timestamp":"\(ts)","message":{"model":"claude-sonnet-4-5",\
            "usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":\(cacheRead),\
            "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
            "output_tokens_details":{"thinking_tokens":0}}}}
            """
        }
        try write([line(cacheRead: 0), line(cacheRead: 500)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 2)
    }

    // MARK: - Day folding for a turn outside the rolling window

    func testATurnOlderThanRecentWindowFoldsWithItsFullSplitAndPerCategoryDollars() async throws {
        // 40 days back: past the 31-day `recentWindow`, so ingest() folds it straight
        // into `oldDays` rather than keeping it in `recentTurns`. The file itself is
        // written just now, so its mtime is well inside the 90-day scan window.
        try write([realShapedLine(id: "msg_old", minutesAgo: 40 * 24 * 60, thinking: 12_000)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let breakdown = await aggregator.breakdown()
        let day = try XCTUnwrap(breakdown.daily.first)

        XCTAssertEqual(day.tokens.input, 1_234_567)
        XCTAssertEqual(day.tokens.cacheRead, 345_678)
        XCTAssertEqual(day.tokens.cacheWrite, 52_467)
        XCTAssertEqual(day.tokens.thinking, 12_000)
        XCTAssertEqual(day.totalTokens, day.tokens.total, "the headline mirrors the folded split's sum")
        let expectedCost = try XCTUnwrap(day.tokens.cost).total
        XCTAssertEqual(expectedCost, day.totalCost, accuracy: 1e-9)
        XCTAssertGreaterThan(day.totalCost, 0)
    }

    // MARK: - byModelToday sums to todayTokenBreakdown

    func testByModelTodayBreakdownsSumToTodaysTokenBreakdown() async throws {
        try write([
            realShapedLine(id: "msg_m1", minutesAgo: 0.1, thinking: 1_000),
            {
                let ts = Self.iso.string(from: now.addingTimeInterval(-6))
                return """
                {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg_m2","model":"claude-opus-4-5",\
                "usage":{"input_tokens":500000,"output_tokens":50000,"cache_read_input_tokens":10000,\
                "cache_creation":{"ephemeral_5m_input_tokens":2000,"ephemeral_1h_input_tokens":0},\
                "output_tokens_details":{"thinking_tokens":3000}}}}
                """
            }(),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let b = await aggregator.breakdown()

        XCTAssertEqual(b.byModelToday.count, 2)
        let summedInput = b.byModelToday.reduce(0) { $0 + $1.breakdown.input }
        let summedOutput = b.byModelToday.reduce(0) { $0 + $1.breakdown.output }
        let summedCacheRead = b.byModelToday.reduce(0) { $0 + $1.breakdown.cacheRead }
        let summedCacheWrite = b.byModelToday.reduce(0) { $0 + $1.breakdown.cacheWrite }
        let summedThinking = b.byModelToday.reduce(0) { $0 + $1.breakdown.thinking }

        XCTAssertEqual(summedInput, b.todayTokenBreakdown.input)
        XCTAssertEqual(summedOutput, b.todayTokenBreakdown.output)
        XCTAssertEqual(summedCacheRead, b.todayTokenBreakdown.cacheRead)
        XCTAssertEqual(summedCacheWrite, b.todayTokenBreakdown.cacheWrite)
        XCTAssertEqual(summedThinking, b.todayTokenBreakdown.thinking)
    }

    // MARK: - usage(from:to:) excludes turns outside the window

    func testWindowBreakdownExcludesATurnOutsideItEvenThoughItsInsideToday() async throws {
        try write([
            realShapedLine(id: "msg_in", minutesAgo: 10, thinking: 500),
            {
                let ts = Self.iso.string(from: now.addingTimeInterval(-5 * 3600)) // 5h ago, still today-ish but outside a 1h window
                return """
                {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg_out","model":"claude-sonnet-4-5",\
                "usage":{"input_tokens":9999999,"output_tokens":9999999,"cache_read_input_tokens":0,\
                "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
                """
            }(),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1, "the 5-hour-old turn must not be inside a 1-hour window")
        XCTAssertEqual(usage.breakdown.input, 1_234_567, "only the in-window turn's tokens appear")
        XCTAssertNotEqual(usage.breakdown.input, 9_999_999 + 1_234_567, "the out-of-window turn must not leak in")
    }

    // MARK: - Cache v1 rejection, v2 round trip, foreign root rejection

    func testAHandWrittenVersionOneSnapshotIsRejectedAndTheRealLogsAreReRead() async throws {
        try write([realShapedLine(id: "msg_cache1", minutesAgo: 10, thinking: 0)])

        let fabricatedDayISO = ISO8601DateFormatter().string(
            from: Calendar.current.startOfDay(for: now.addingTimeInterval(-15 * 24 * 3600))
        )
        let object: [String: Any] = [
            "version": 1,
            "root": root.path,
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [[
                "day": fabricatedDayISO,
                "cost": 555.0,
                "tokens": 555_555,
                "breakdown": [
                    "input": 555_555, "output": 0, "cacheRead": 0,
                    "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
                ],
                "turns": 9,
                "byFamily": ["sonnet": 555.0],
            ]],
            "seenMessageIDs": [Any](),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()
        let parsed = await aggregator.filesParsedInLastScan
        let breakdown = await aggregator.breakdown()

        XCTAssertGreaterThan(parsed, 0, "a v1 snapshot must not stop the real logs from being read")
        XCTAssertFalse(
            breakdown.daily.contains { $0.turns == 9 || $0.tokens.input == 555_555 },
            "nothing fabricated in the rejected v1 snapshot may reach the real figures"
        )
        // The real ingested turn is present with correct numbers, proving re-ingest gives
        // the same figures a cold, uncached run would.
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(usage.breakdown.input, 1_234_567)
    }

    func testAV2RoundTripPreservesDayEntryTokensIncludingCost() async throws {
        try write([realShapedLine(id: "msg_cache2", minutesAgo: 40 * 24 * 60, thinking: 7_000)])

        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await first.refresh()
        let firstBreakdown = await first.breakdown()
        let firstDay = try XCTUnwrap(firstBreakdown.daily.first)

        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await second.refresh()
        let secondParsed = await second.filesParsedInLastScan
        let secondBreakdown = await second.breakdown()
        let secondDay = try XCTUnwrap(secondBreakdown.daily.first)

        XCTAssertEqual(secondParsed, 0, "the v2 cache must answer without reopening the transcript")
        XCTAssertEqual(secondDay.tokens, firstDay.tokens, "the whole breakdown, cost included, round-trips through Codable")
        XCTAssertEqual(try XCTUnwrap(secondDay.tokens.cost).total, secondDay.totalCost, accuracy: 1e-9)
        XCTAssertEqual(secondDay.tokens.thinking, 7_000)
    }

    func testASnapshotWrittenForAnotherRootIsRejected() async throws {
        try write([realShapedLine(id: "msg_foreign", minutesAgo: 10, thinking: 0)])

        let object: [String: Any] = [
            // The current version, so the rejection under test is the root's and not
            // the version's.
            "version": 3,
            "root": "/completely/different/root/that/is/not/this/tests/root",
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [[
                "day": ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: now)),
                "cost": 42.0,
                "tokens": 42,
                "breakdown": [
                    "input": 42, "output": 0, "cacheRead": 0,
                    "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
                ],
                "turns": 1,
                "byFamily": ["sonnet": 42.0],
            ]],
            "seenMessageIDs": [Any](),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()
        let parsed = await aggregator.filesParsedInLastScan
        let breakdown = await aggregator.breakdown()

        XCTAssertGreaterThan(parsed, 0, "a cache for another root must trigger a full rescan")
        XCTAssertFalse(breakdown.daily.contains { $0.turns == 1 && $0.tokens.input == 42 })
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(usage.breakdown.input, 1_234_567, "the real log's own turn is what gets counted")
    }
}
