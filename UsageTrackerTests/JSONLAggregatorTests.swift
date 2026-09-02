import XCTest
@testable import Omelette

/// Fixture logs mimic what Claude Code writes to `~/.claude/projects/<slug>/<uuid>.jsonl`.
/// Costs are asserted in dollars against the static `ModelPricing` table, which is what
/// the app uses offline — `ModelsDevPricing` never runs in this target, so nothing
/// network-dependent can move these numbers.
final class JSONLAggregatorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let betaSlug = "-Users-tester-Projects-beta"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// The cache file lives beside the log root, never inside it — and never in the
    /// real Application Support directory, which no test may touch.
    private var cacheURL: URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-cost-cache.json")
    }

    // MARK: - Fixture writing

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func line(
        id: String,
        minutesAgo: Double,
        model: String,
        input: Int,
        output: Int = 0,
        cacheRead: Int = 0,
        timestamp: String? = nil
    ) -> String {
        let ts = timestamp ?? Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    private func write(_ lines: [String], project: String, file: String = "session.jsonl") throws {
        try writeRaw(lines.joined(separator: "\n") + "\n", project: project, file: file)
    }

    /// Writes exactly the bytes given — no terminator added — so a half-written tail
    /// line can be reproduced.
    private func writeRaw(_ contents: String, project: String, file: String = "session.jsonl") throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Two projects, four distinct turns, one duplicated log line, one turn well
    /// outside the two-hour window under test.
    private func writeStandardFixture() throws {
        let a1 = line(id: "msg_a1", minutesAgo: 90, model: "claude-sonnet-4-5", input: 1_000_000)
        try write([
            a1,
            line(id: "msg_a2", minutesAgo: 60, model: "claude-opus-4-5", input: 1_000_000),
            a1, // Claude Code logs the same response several times; it must count once.
            line(id: "msg_old", minutesAgo: 300, model: "claude-sonnet-4-5", input: 1_000_000),
        ], project: alphaSlug)
        try write([
            line(id: "msg_b1", minutesAgo: 30, model: "claude-sonnet-4-5", input: 500_000),
        ], project: betaSlug)
    }

    private func loadedAggregator() async throws -> JSONLAggregator {
        try writeStandardFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        return aggregator
    }

    // MARK: - Pricing assumptions these tests are written against

    func testStaticPricingMatchesTheAssumedRates() {
        // If these move, the dollar figures below are stale — fail here rather than
        // somewhere less obvious.
        XCTAssertEqual(ModelPricing.table["claude-sonnet-4-5"]?.inputPerM, 3)
        XCTAssertEqual(ModelPricing.table["claude-opus-4-5"]?.inputPerM, 5)
    }

    // MARK: - usage(from:to:)

    func testWindowSumsOnlyTheTurnsInsideIt() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.turns, 3, "the duplicate and the 5-hour-old turn must not count")
        XCTAssertEqual(usage.tokens, 2_500_000)
        XCTAssertEqual(usage.cost, 9.5, accuracy: 0.0001) // $3.00 + $5.00 + $1.50
        XCTAssertFalse(usage.isEmpty)
    }

    func testWindowRanksProjectsByCost() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.projects.map(\.slug), [alphaSlug, betaSlug])
        XCTAssertEqual(usage.projects[0].totalCost, 8.0, accuracy: 0.0001)
        XCTAssertEqual(usage.projects[0].turns, 2)
        XCTAssertEqual(usage.projects[1].totalCost, 1.5, accuracy: 0.0001)
        XCTAssertEqual(usage.projects[1].turns, 1)
    }

    func testWindowRanksModelsByCost() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.models.map { $0.model }, ["Opus 4.5", "Sonnet 4.5"])
        XCTAssertEqual(usage.models[0].cost, 5.0, accuracy: 0.0001)
        XCTAssertEqual(usage.models[1].cost, 4.5, accuracy: 0.0001) // both Sonnet turns
        XCTAssertEqual(usage.models[1].tokens, 1_500_000)
    }

    func testAWindowWithNothingInItIsEmpty() async throws {
        let aggregator = try await loadedAggregator()
        let usage = await aggregator.usage(
            from: now.addingTimeInterval(-4 * 3600),
            to: now.addingTimeInterval(-3 * 3600)
        )

        XCTAssertTrue(usage.isEmpty)
        XCTAssertEqual(usage.turns, 0)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokens, 0)
        XCTAssertTrue(usage.projects.isEmpty)
        XCTAssertTrue(usage.models.isEmpty)
    }

    func testARescanDoesNotDoubleCount() async throws {
        let aggregator = try await loadedAggregator()
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-2 * 3600), to: now)

        XCTAssertEqual(usage.turns, 3)
        XCTAssertEqual(usage.cost, 9.5, accuracy: 0.0001)
    }

    // MARK: - breakdown()

    func testBreakdownCoversTheWholeWeekAndRanksProjects() async throws {
        let aggregator = try await loadedAggregator()
        let breakdown = await aggregator.breakdown()

        // Everything in the fixture is inside the last 24 hours, so week and month agree.
        XCTAssertEqual(breakdown.weekCost, 12.5, accuracy: 0.0001) // adds the 5-hour-old $3.00
        XCTAssertEqual(breakdown.monthCost, 12.5, accuracy: 0.0001)
        XCTAssertEqual(breakdown.projectsWeek.map(\.slug), [alphaSlug, betaSlug])
        XCTAssertEqual(breakdown.projectsWeek[0].totalCost, 11.0, accuracy: 0.0001)
        XCTAssertEqual(breakdown.projectsWeek[0].turns, 3)
        XCTAssertEqual(breakdown.projectsWeek[1].totalCost, 1.5, accuracy: 0.0001)
    }

    func testAnEmptyLogRootProducesNothing() async throws {
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let breakdown = await aggregator.breakdown()

        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertTrue(breakdown.projectsWeek.isEmpty)
        XCTAssertTrue(usage.isEmpty)
    }

    // MARK: - Cost table coverage

    func testOutputAndCacheReadTokensArePricedAtTheirOwnRates() async throws {
        // Input is the only rate the fixtures above exercise. These are the other two
        // that matter: a million output tokens and a million cache reads on Sonnet 4.5.
        try write([
            line(id: "msg_out", minutesAgo: 10, model: "claude-sonnet-4-5", input: 0, output: 1_000_000),
        ], project: alphaSlug)
        try write([
            line(id: "msg_cache", minutesAgo: 10, model: "claude-sonnet-4-5", input: 0, cacheRead: 1_000_000),
        ], project: betaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.tokens, 2_000_000)
        // $15.00 of output + $0.30 of cache reads.
        XCTAssertEqual(usage.cost, 15.30, accuracy: 0.0001)
        XCTAssertEqual(usage.projects.first { $0.slug == alphaSlug }?.totalCost ?? 0, 15.0, accuracy: 0.0001)
        XCTAssertEqual(usage.projects.first { $0.slug == betaSlug }?.totalCost ?? 0, 0.30, accuracy: 0.0001)
    }

    func testTheAssumedOutputAndCacheReadRates() {
        // Same guard as the input rates above: if these move, the dollars do.
        XCTAssertEqual(ModelPricing.table["claude-sonnet-4-5"]?.outputPerM, 15)
        XCTAssertEqual(ModelPricing.table["claude-sonnet-4-5"]?.cacheReadPerM, 0.3)
    }

    // MARK: - Partially written lines

    func testALineWithoutItsTerminatorIsLeftForTheNextPoll() async throws {
        // A poll can land between the write of a line's bytes and its newline. Counting
        // the file as fully consumed skipped that turn AND guaranteed it would never be
        // read again.
        let first = line(id: "msg_partial", minutesAgo: 10, model: "claude-sonnet-4-5", input: 1_000_000)
        try writeRaw(first, project: alphaSlug) // no trailing newline

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let beforeTerminator = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(beforeTerminator.turns, 0, "a half-written line is not a turn yet")

        // Claude Code finishes the line and writes the next one.
        let second = line(id: "msg_second", minutesAgo: 5, model: "claude-sonnet-4-5", input: 500_000)
        try writeRaw(first + "\n" + second + "\n", project: alphaSlug)
        await aggregator.refresh()

        let after = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(after.turns, 2, "the completed line must arrive, and exactly once")
        XCTAssertEqual(after.cost, 4.5, accuracy: 0.0001) // $3.00 + $1.50
    }

    // MARK: - Timestamps

    func testATimestampWithoutFractionalSecondsStillParses() async throws {
        // Claude Code always writes fractions today; a writer that stops must not cost
        // us the turn's place in time.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(identifier: "UTC")
        let stamped = now.addingTimeInterval(-10 * 60)

        try write([
            line(
                id: "msg_plain", minutesAgo: 0, model: "claude-sonnet-4-5", input: 1_000_000,
                timestamp: plain.string(from: stamped)
            ),
        ], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        // The whole second the fraction-less stamp rounds to, and nothing else.
        let expected = plain.date(from: plain.string(from: stamped))!
        let usage = await aggregator.usage(
            from: expected, to: expected.addingTimeInterval(0.5)
        )

        XCTAssertEqual(usage.turns, 1, "the date has to land on the second it names")
        XCTAssertEqual(usage.cost, 3.0, accuracy: 0.0001)
    }

    func testAnUndatableLineIsDroppedRatherThanBilledAsNow() async throws {
        // `?? Date()` put a turn nobody can place into today's spend and into whatever
        // rate window happens to be open — the one case where a wrong answer is worse
        // than none.
        try write([
            line(
                id: "msg_garbage", minutesAgo: 0, model: "claude-sonnet-4-5", input: 1_000_000,
                timestamp: "the day before yesterday"
            ),
            line(id: "msg_good", minutesAgo: 10, model: "claude-sonnet-4-5", input: 500_000),
        ], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        // The window reaches forward as well as back: `?? Date()` stamps the turn at
        // whatever moment the parse ran, which is *after* the fixture's `now`, so a
        // backward-only window would miss the very turn this is about.
        let usage = await aggregator.usage(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600)
        )

        XCTAssertEqual(usage.turns, 1, "only the datable line counts")
        XCTAssertEqual(usage.cost, 1.5, accuracy: 0.0001)
    }

    func testNonAssistantAndSyntheticLinesAreSkipped() async throws {
        try write([
            #"{"type":"user","timestamp":"\#(Self.iso.string(from: now))","message":{"id":"msg_u","role":"user"}}"#,
            line(id: "msg_synthetic", minutesAgo: 10, model: "<synthetic>", input: 1_000_000),
            line(id: "msg_real", minutesAgo: 10, model: "claude-sonnet-4-5", input: 1_000_000),
        ], project: alphaSlug)
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.cost, 3.0, accuracy: 0.0001)
    }

    // MARK: - The on-disk cache

    /// Appends bytes to an existing fixture file the way Claude Code does — the size
    /// and the mtime both move, which is what the scanner keys off.
    private func append(_ text: String, project: String, file: String = "session.jsonl") throws {
        let url = root.appendingPathComponent(project, isDirectory: true).appendingPathComponent(file)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private let twoHourWindow = 2.0 * 3600

    func testACachedRelaunchProducesTheSameFiguresWithoutReparsing() async throws {
        try writeStandardFixture()
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await first.refresh()
        let firstBreakdown = await first.breakdown()
        let firstParsed = await first.filesParsedInLastScan
        XCTAssertEqual(firstParsed, 2, "a cold start reads both transcripts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "the cache must be written")

        // A relaunch: same logs, same cache, nothing touched in between.
        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await second.refresh()
        let secondParsed = await second.filesParsedInLastScan
        let secondBreakdown = await second.breakdown()

        XCTAssertEqual(secondParsed, 0, "unchanged transcripts must not be opened at all")
        XCTAssertEqual(secondBreakdown.todayCost, firstBreakdown.todayCost, accuracy: 0.0001)
        XCTAssertEqual(secondBreakdown.todayTokens, firstBreakdown.todayTokens)
        XCTAssertEqual(secondBreakdown.todayTurns, firstBreakdown.todayTurns)
        XCTAssertEqual(secondBreakdown.weekCost, firstBreakdown.weekCost, accuracy: 0.0001)
        XCTAssertEqual(secondBreakdown.monthCost, firstBreakdown.monthCost, accuracy: 0.0001)
        XCTAssertEqual(secondBreakdown.projectsWeek.map(\.slug), firstBreakdown.projectsWeek.map(\.slug))
        XCTAssertEqual(
            secondBreakdown.projectsWeek.map(\.totalCost),
            firstBreakdown.projectsWeek.map(\.totalCost)
        )
        XCTAssertEqual(secondBreakdown.daily.map(\.turns), firstBreakdown.daily.map(\.turns))
    }

    func testOnlyTheChangedFileIsReparsedAfterARestart() async throws {
        try writeStandardFixture()
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await first.refresh()
        let before = await first.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        // One project keeps working while the app is closed.
        try append(
            line(id: "msg_b2", minutesAgo: 20, model: "claude-sonnet-4-5", input: 1_000_000) + "\n",
            project: betaSlug
        )

        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let after = await second.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(parsed, 1, "only the transcript that changed is opened")
        XCTAssertEqual(after.turns, before.turns + 1)
        XCTAssertEqual(after.cost, before.cost + 3.0, accuracy: 0.0001)
        XCTAssertEqual(after.tokens, before.tokens + 1_000_000)
    }

    func testARewrittenFileIsReparsedWithoutDoubleCounting() async throws {
        try writeStandardFixture()
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await first.refresh()
        let before = await first.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        // The session file is rewritten shorter than the offset we recorded — a
        // compaction, a rollback, a crash mid-write.
        let a1 = line(id: "msg_a1", minutesAgo: 90, model: "claude-sonnet-4-5", input: 1_000_000)
        let a2 = line(id: "msg_a2", minutesAgo: 60, model: "claude-opus-4-5", input: 1_000_000)
        try writeRaw(a1 + "\n" + a2 + "\n", project: alphaSlug)

        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let after = await second.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(parsed, 1, "a shorter file is read again from the top")
        XCTAssertEqual(after.turns, before.turns, "the replayed lines are already counted")
        XCTAssertEqual(after.cost, before.cost, accuracy: 0.0001)
    }

    func testACorruptOrForeignCacheIsIgnored() async throws {
        try writeStandardFixture()
        let uncached = JSONLAggregator(rootURL: root, cacheURL: nil)
        await uncached.refresh()
        let expected = await uncached.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        try "{not json".write(to: cacheURL, atomically: true, encoding: .utf8)
        let afterCorrupt = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await afterCorrupt.refresh()
        let corruptParsed = await afterCorrupt.filesParsedInLastScan
        let fromCorrupt = await afterCorrupt.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(corruptParsed, 2, "an unreadable cache means a full rescan")
        XCTAssertEqual(fromCorrupt.turns, expected.turns)
        XCTAssertEqual(fromCorrupt.cost, expected.cost, accuracy: 0.0001)

        // Well-formed, but written for somebody else's log root.
        let foreign: [String: Any] = [
            "version": 1,
            "root": "/somewhere/else/projects",
            "savedAt": "2026-01-01T00:00:00Z",
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [Any](),
            "seenMessageIDs": [Any](),
        ]
        try JSONSerialization.data(withJSONObject: foreign).write(to: cacheURL)
        let afterForeign = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await afterForeign.refresh()
        let foreignParsed = await afterForeign.filesParsedInLastScan
        let fromForeign = await afterForeign.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(foreignParsed, 2, "a cache for another log root means a full rescan")
        XCTAssertEqual(fromForeign.turns, expected.turns)
        XCTAssertEqual(fromForeign.cost, expected.cost, accuracy: 0.0001)
    }

    func testTheCacheIsNotRewrittenOnAQuietPoll() async throws {
        try writeStandardFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()

        let written = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let writtenAt = try XCTUnwrap(written[.modificationDate] as? Date)
        let writtenSize = try XCTUnwrap(written[.size] as? Int)

        // The minute poll with nothing new in the logs: no turns, no marks, no write.
        await aggregator.refresh()
        let afterPoll = try FileManager.default.attributesOfItem(atPath: cacheURL.path)

        XCTAssertEqual(afterPoll[.modificationDate] as? Date, writtenAt, "a quiet poll must not rewrite the cache")
        XCTAssertEqual(afterPoll[.size] as? Int, writtenSize)
    }
}
