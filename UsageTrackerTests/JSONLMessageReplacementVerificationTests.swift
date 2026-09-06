import XCTest
@testable import Omelette

/// Independent verification of the "later record wins" fix in `JSONLAggregator`
/// (commit 372e553: an id→index map over `recentTurns`, keyed by the same FNV-1a hash
/// `seenMessageIDs` uses, so a bigger later record revises a turn in place) and the
/// related cache-write fix (commit 0e13e9d: `cache_creation_input_tokens` with no TTL
/// object still bills as a 5-minute write). Written without reading
/// `JSONLAggregatorTests` or the existing `JSONLAggregatorVerificationTests` (a prior
/// verification round for a different package); covers interleaving, index correctness
/// across a cache round trip with more than one entry, the folded-id no-op path, the
/// partial-tail rule across more than one poll, and cache version rejection.
final class JSONLMessageReplacementVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLMessageReplacementVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    private func line(
        id: String, minutesAgo: Double, model: String = "claude-sonnet-4-5",
        input: Int, output: Int, thinking: Int = 0,
        cacheCreationAggregate: Int? = nil
    ) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        let aggregate = cacheCreationAggregate.map { ",\"cache_creation_input_tokens\":\($0)" } ?? ""
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0\(aggregate),\
        "output_tokens_details":{"thinking_tokens":\(thinking)}}}}
        """
    }

    private func write(_ lines: [String], project: String, file: String = "session.jsonl") throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
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

    // MARK: - cache_creation_input_tokens with no TTL object

    func testCacheCreationAggregateWithNoTTLObjectIsBilledAsAFiveMinuteWrite() async throws {
        try write([
            line(id: "msg_agg", minutesAgo: 5, input: 1_000_000, output: 0, cacheCreationAggregate: 400_000),
        ], project: "proj")
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.breakdown.cacheWrite5m, 400_000, "no TTL object, so the aggregate bills at the cheaper 5m tier")
        XCTAssertEqual(usage.breakdown.cacheWrite1h, 0)
    }

    func testAZeroCacheCreationAggregateContributesNothing() async throws {
        try write([
            line(id: "msg_agg_zero", minutesAgo: 5, input: 1_000_000, output: 0, cacheCreationAggregate: 0),
        ], project: "proj")
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.breakdown.cacheWrite5m, 0)
        XCTAssertEqual(usage.breakdown.cacheWrite1h, 0)
    }

    // MARK: - Interleaved ids

    func testTwoInterleavedMessageIdsAreRevisedIndependently() async throws {
        // A provisional line for A, then for B, then the final for A, then the final
        // for B — a realistic interleaving when two responses are in flight.
        try write([
            line(id: "msg_A", minutesAgo: 20, input: 500_000, output: 2),
            line(id: "msg_B", minutesAgo: 19, input: 700_000, output: 3),
            line(id: "msg_A", minutesAgo: 20, input: 500_000, output: 90_000, thinking: 40_000),
            line(id: "msg_B", minutesAgo: 19, input: 700_000, output: 60_000, thinking: 10_000),
        ], project: "proj")
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 2, "two distinct ids, however interleaved, are two turns")
        XCTAssertEqual(usage.breakdown.output, 150_000, "both final counts, neither provisional one")
        XCTAssertEqual(usage.breakdown.thinking, 50_000)
    }

    // MARK: - Index correctness across a cache round trip with more than one entry

    func testAReplacementAfterACacheRoundTripUpdatesOnlyTheMatchingIndexedTurn() async throws {
        // Two turns land in `recentTurns` in the same poll, so the id→index map has to
        // point at the right slot for each — not just "the only slot" the way a
        // single-entry round trip would prove.
        try write([
            line(id: "msg_first", minutesAgo: 20, input: 100_000, output: 2),
            line(id: "msg_second", minutesAgo: 15, input: 200_000, output: 3),
        ], project: "proj")
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await first.refresh()
        let before = await first.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(before.turns, 2)
        XCTAssertEqual(before.breakdown.output, 5, "both still provisional (2 + 3)")

        // Only the FIRST turn gets its final record. The second must be untouched.
        try append(
            line(id: "msg_first", minutesAgo: 20, input: 100_000, output: 50_000, thinking: 1_000) + "\n",
            project: "proj"
        )
        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await second.refresh()
        let after = await second.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(after.turns, 2, "still two turns, not merged into one")
        XCTAssertEqual(after.breakdown.output, 50_003, "50_000 (revised first) + 3 (untouched second)")
        XCTAssertEqual(after.breakdown.thinking, 1_000)
    }

    // MARK: - A replacement for an id already folded into oldDays

    func testAReplacementForAnAlreadyFoldedIdIsIgnoredWithoutCrashing() async throws {
        // The old turn is more than `recentWindow` (31 days) in the past, so it goes
        // straight to `fold()` at ingest and is never placed in the id→index map. A
        // later "replacement" line for that same id must find no index entry and be
        // silently dropped rather than crash or revise a folded aggregate.
        let oldMinutesAgo = 40.0 * 24 * 60
        try write([
            line(id: "msg_old", minutesAgo: oldMinutesAgo, input: 1_000_000, output: 10_000),
            line(id: "msg_recent", minutesAgo: 10, input: 50_000, output: 500),
        ], project: "proj")
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let before = await aggregator.breakdown()
        let oldDayBefore = try XCTUnwrap(before.daily.first { $0.turns >= 1 && $0.tokens.output == 10_000 })

        try append(
            line(id: "msg_old", minutesAgo: oldMinutesAgo, input: 1_000_000, output: 999_999) + "\n",
            project: "proj"
        )
        await aggregator.refresh()
        let after = await aggregator.breakdown()
        let oldDayAfter = try XCTUnwrap(after.daily.first { $0.day == oldDayBefore.day })

        XCTAssertEqual(oldDayAfter.tokens.output, 10_000, "the folded day is not revised by a later duplicate")
        XCTAssertEqual(oldDayAfter.turns, oldDayBefore.turns, "no crash, and no phantom extra turn either")

        // The unrelated recent turn must still be intact.
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(usage.breakdown.output, 500, "the recent turn survived the same poll, untouched")
    }

    // MARK: - Partial tail across more than one poll

    func testAFinalLineWrittenWithoutATrailingNewlineIsNotAdoptedUntilCompleted() async throws {
        // Poll 1: the provisional line, complete with its own newline.
        try write([line(id: "msg_partial", minutesAgo: 10, input: 100_000, output: 2)], project: "proj")
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let poll1 = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(poll1.breakdown.output, 2)

        // Poll 2: the final line's bytes arrive, but the writer hasn't flushed the
        // trailing newline yet — the aggregator must not adopt a half-written line.
        let finalLine = line(id: "msg_partial", minutesAgo: 10, input: 100_000, output: 77_000, thinking: 3_000)
        try append(finalLine, project: "proj") // no "\n"
        await aggregator.refresh()
        let poll2 = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(poll2.breakdown.output, 2, "the incomplete tail must not be parsed yet")

        // Poll 3: the newline lands (a separate write, as a real flush would do).
        try append("\n", project: "proj")
        await aggregator.refresh()
        let poll3 = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(poll3.breakdown.output, 77_000, "now the line is complete and replaces the provisional turn")
        XCTAssertEqual(poll3.breakdown.thinking, 3_000)
        XCTAssertEqual(poll3.turns, 1, "still one turn, not two")
    }

    // MARK: - Cache version rejection

    func testAVersionOneCacheSnapshotIsRejectedWholesale() async throws {
        try write([line(id: "msg_v1", minutesAgo: 30, input: 10_000, output: 1_000)], project: "proj")

        let fabricatedDay = ISO8601DateFormatter().string(
            from: Calendar.current.startOfDay(for: now.addingTimeInterval(-5 * 24 * 3600))
        )
        let object: [String: Any] = [
            "version": 1,
            "root": root.path,
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [[
                "day": fabricatedDay,
                "cost": 500.0,
                "tokens": 999_999,
                "breakdown": [
                    "input": 999_999, "output": 0, "cacheRead": 0,
                    "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
                ],
                "turns": 42,
                "byFamily": ["sonnet": 500.0],
            ]],
            "seenMessageIDs": [Any](),
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: cacheURL)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()
        let parsed = await aggregator.filesParsedInLastScan
        let breakdown = await aggregator.breakdown()

        XCTAssertEqual(parsed, 1, "a version-1 snapshot forces a full rescan of the one file")
        XCTAssertFalse(
            breakdown.daily.contains { $0.turns == 42 },
            "the fabricated version-1 day must not reach the figures"
        )
    }
}
