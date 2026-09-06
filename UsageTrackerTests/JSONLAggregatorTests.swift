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
        try? FileManager.default.removeItem(at: cacheFile(named: "control"))
    }

    /// The cache file lives beside the log root, never inside it — and never in the
    /// real Application Support directory, which no test may touch.
    private var cacheURL: URL { cacheFile(named: "cost-cache") }

    private func cacheFile(named name: String) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name).json")
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
        cacheCreate5m: Int = 0,
        cacheCreate1h: Int = 0,
        thinking: Int? = nil,
        timestamp: String? = nil
    ) -> String {
        let ts = timestamp ?? Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        // `output_tokens_details` is new in the logs; a line without it is the older
        // shape every existing fixture uses, and must still parse (thinking 0).
        let details = thinking.map { ",\"output_tokens_details\":{\"thinking_tokens\":\($0)}" } ?? ""
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(cacheCreate5m),\
        "ephemeral_1h_input_tokens":\(cacheCreate1h)}\(details)}}}
        """
    }

    /// A line with no `message.id` — older Claude Code builds. Identity then has to come
    /// from the content, which is what the dedup fallback key is for.
    private func idlessLine(minutesAgo: Double, model: String, input: Int, output: Int, thinking: Int) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens_details":{"thinking_tokens":\(thinking)}}}}
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

    func testCacheWritesAreThrottledWhileIngesting() async throws {
        try writeStandardFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()
        let firstWrite = try cacheStamp()

        // A poll five seconds later that really does ingest something. The snapshot
        // runs to tens of MB on a busy machine; rewriting it per turn is the cost the
        // throttle exists to avoid.
        try append(
            line(id: "msg_b2", minutesAgo: 20, model: "claude-sonnet-4-5", input: 1_000_000) + "\n",
            project: betaSlug
        )
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(usage.turns, 4, "the turn is counted straight away")
        XCTAssertEqual(try cacheStamp(), firstWrite, "…but the file is not rewritten for it")

        // The same sequence with the throttle off, so the assertion above is about the
        // interval and not about a save path that quietly stopped working.
        let control = JSONLAggregator(
            rootURL: root, cacheURL: cacheFile(named: "control"), saveInterval: 0
        )
        await control.refresh()
        let controlFirst = try cacheStamp(cacheFile(named: "control"))
        try append(
            line(id: "msg_b3", minutesAgo: 15, model: "claude-sonnet-4-5", input: 1_000_000) + "\n",
            project: betaSlug
        )
        await control.refresh()
        XCTAssertNotEqual(try cacheStamp(cacheFile(named: "control")), controlFirst)
    }

    func testFlushCacheWritesImmediately() async throws {
        try writeStandardFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await aggregator.refresh()
        let firstWrite = try cacheStamp()

        try append(
            line(id: "msg_b2", minutesAgo: 20, model: "claude-sonnet-4-5", input: 1_000_000) + "\n",
            project: betaSlug
        )
        await aggregator.refresh()
        XCTAssertEqual(try cacheStamp(), firstWrite, "still inside the throttle window")

        // Quitting: what the throttle is holding back has to reach disk now.
        await aggregator.flushCache()
        XCTAssertNotEqual(try cacheStamp(), firstWrite, "the flush must not wait for the interval")

        // And the flushed cache is complete: the next launch counts that turn without
        // reading a single transcript.
        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await relaunched.refresh()
        let parsed = await relaunched.filesParsedInLastScan
        let usage = await relaunched.usage(from: now.addingTimeInterval(-twoHourWindow), to: now)

        XCTAssertEqual(parsed, 0)
        XCTAssertEqual(usage.turns, 4)
        XCTAssertEqual(usage.cost, 12.5, accuracy: 0.0001)
    }

    /// Size and mtime together: either moving means the file was rewritten.
    private func cacheStamp(_ url: URL? = nil) throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: (url ?? cacheURL).path)
        let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
        let size = try XCTUnwrap(attrs[.size] as? Int)
        return ["\(modified.timeIntervalSince1970)", "\(size)"]
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

    func testAVersionTwoCacheIsRejectedAndTheLogsAreReRead() async throws {
        try writeStandardFixture()

        // A snapshot in the *current* shape, wearing the old version number, with a day
        // of spend the logs cannot produce. Only the version check can reject it — a
        // decode failure would prove nothing about the bump.
        let fabricatedDay = ISO8601DateFormatter().string(
            from: Calendar.current.startOfDay(for: now.addingTimeInterval(-10 * 24 * 3600))
        )
        func snapshot(version: Int) -> Data {
            let object: [String: Any] = [
                "version": version,
                "root": root.path,
                "savedAt": ISO8601DateFormatter().string(from: now),
                "fileMarks": [String: Any](),
                "recentTurns": [Any](),
                "oldDays": [[
                    "day": fabricatedDay,
                    "cost": 99.0,
                    "tokens": 12_345,
                    "breakdown": [
                        "input": 12_345, "output": 0, "cacheRead": 0,
                        "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
                    ],
                    "turns": 7,
                    "byFamily": ["sonnet": 99.0],
                ]],
                "seenMessageIDs": [Any](),
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        try snapshot(version: 2).write(to: cacheURL)
        let stale = JSONLAggregator(rootURL: root, cacheURL: cacheURL)
        await stale.refresh()
        let staleParsed = await stale.filesParsedInLastScan
        let staleBreakdown = await stale.breakdown()

        XCTAssertEqual(staleParsed, 2, "a version-2 snapshot means a full rescan")
        XCTAssertFalse(
            staleBreakdown.daily.contains { $0.turns == 7 },
            "nothing from the old snapshot may reach the figures"
        )
        XCTAssertEqual(staleBreakdown.weekCost, 12.5, accuracy: 0.0001)

        // The control: the same bytes at version 3 ARE restored, so the assertions
        // above are about the version number and not about an unreadable file.
        let currentURL = cacheFile(named: "control")
        try snapshot(version: 3).write(to: currentURL)
        let current = JSONLAggregator(rootURL: root, cacheURL: currentURL)
        await current.refresh()
        let currentBreakdown = await current.breakdown()

        XCTAssertTrue(
            currentBreakdown.daily.contains { $0.turns == 7 && $0.tokens.input == 12_345 },
            "a current snapshot restores its folded days, breakdown and all"
        )
    }

    func testAFoldedOldDayKeepsItsBreakdownAcrossTheCache() async throws {
        // 40 days back: past `recentWindow`, so the turn is folded into `oldDays` at
        // ingest and only the day-level aggregate is ever written to the cache. The
        // file itself is new, so the mtime window still lets the scanner read it.
        try write([
            line(
                id: "msg_folded", minutesAgo: 40 * 24 * 60, model: "claude-sonnet-4-5",
                input: 1_000_000, output: 200_000, cacheRead: 500_000,
                cacheCreate5m: 100_000, cacheCreate1h: 10_000, thinking: 50_000
            ),
        ], project: alphaSlug)

        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await first.refresh()
        let firstBreakdown = await first.breakdown()
        let before = try XCTUnwrap(firstBreakdown.daily.first)
        XCTAssertEqual(before.tokens.input, 1_000_000, "the fold has to keep the split")
        XCTAssertEqual(before.tokens.cacheWrite, 110_000)
        XCTAssertEqual(before.tokens.thinking, 50_000)

        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let secondBreakdown = await second.breakdown()
        let after = try XCTUnwrap(secondBreakdown.daily.first)

        XCTAssertEqual(parsed, 0, "the cache answers without reopening the transcript")
        XCTAssertEqual(after.day, before.day)
        XCTAssertEqual(after.tokens, before.tokens, "including the per-category dollars")
        XCTAssertEqual(after.totalTokens, before.tokens.total)
        XCTAssertEqual(after.totalCost, before.totalCost, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(after.tokens.cost).total, after.totalCost, accuracy: 1e-9)
    }

    // MARK: - Per-turn token breakdown

    func testATurnsCategoryDollarsAddUpToItsCost() throws {
        // The two paths to the same money: `cost` sums the buckets at their rates,
        // `tokens.cost` keeps them apart. They must agree to the cent and well beyond.
        let tokens = TokenBreakdown(
            input: 1_000_000, output: 250_000, cacheRead: 3_000_000,
            cacheWrite5m: 400_000, cacheWrite1h: 50_000, thinking: 60_000
        ).priced(model: "claude-opus-4-5")
        let turn = CLITurn(
            id: "msg_x", timestamp: now, model: "claude-opus-4-5",
            tokens: tokens, projectSlug: alphaSlug
        )

        XCTAssertEqual(try XCTUnwrap(turn.tokens.cost).total, turn.cost, accuracy: 1e-9)
        XCTAssertEqual(turn.totalTokens, turn.tokens.total)
        XCTAssertEqual(turn.totalTokens, 4_700_000, "thinking is not part of the total")
        // The compatibility shims the rest of the app still reads.
        XCTAssertEqual(turn.inputTokens, 1_000_000)
        XCTAssertEqual(turn.outputTokens, 250_000)
        XCTAssertEqual(turn.cacheReadTokens, 3_000_000)
        XCTAssertEqual(turn.cacheCreate5mTokens, 400_000)
        XCTAssertEqual(turn.cacheCreate1hTokens, 50_000)
    }

    func testATurnsDollarsAreTheOnesStoredWithItNotTodaysRates() throws {
        // `tokens.cost` is priced once, when the line is parsed. `cost` used to
        // multiply through the rate table on every read, so any price change after
        // ingest — a models.dev refresh, a new rate landing — left the headline dollars
        // and the per-category dollars describing the same turn differently.
        let stored = TokenCostBreakdown(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        let turn = CLITurn(
            id: "msg_stored", timestamp: now, model: "claude-sonnet-4-5",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000, cost: stored),
            projectSlug: alphaSlug
        )

        XCTAssertEqual(turn.cost, 10, accuracy: 1e-9, "the dollars stored with the turn")
        XCTAssertEqual(try XCTUnwrap(turn.tokens.cost).total, turn.cost, accuracy: 1e-9)
    }

    func testATurnWithNoStoredDollarsStillPricesFromTheTable() throws {
        // Nothing this aggregator parses arrives unpriced, but the type allows it and
        // the fallback has to stay right.
        let turn = CLITurn(
            id: "msg_unpriced", timestamp: now, model: "claude-sonnet-4-5",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000),
            projectSlug: alphaSlug
        )

        XCTAssertEqual(turn.cost, 18, accuracy: 1e-9) // $3.00 of input + $15.00 of output
    }

    func testThinkingTokensAreParsedWithoutInflatingTheTotal() async throws {
        try write([
            line(
                id: "msg_think", minutesAgo: 10, model: "claude-sonnet-4-5",
                input: 1_000_000, output: 200_000, thinking: 50_000
            ),
        ], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.tokens, 1_200_000, "thinking is a subset of output, never an addition")
        XCTAssertEqual(usage.cost, 6.0, accuracy: 0.0001) // $3.00 of input + $3.00 of output
    }

    func testIdlessLinesThatDifferOnlyInThinkingAreTwoTurns() async throws {
        // Without a message id the dedup key is the content; thinking has to be part of
        // it, or a turn that differs only there is silently swallowed as a duplicate.
        let a = idlessLine(minutesAgo: 10, model: "claude-sonnet-4-5", input: 1_000_000, output: 200_000, thinking: 10_000)
        let b = idlessLine(minutesAgo: 10, model: "claude-sonnet-4-5", input: 1_000_000, output: 200_000, thinking: 90_000)
        try write([a, a, b], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 2, "identical content is one turn; a different thinking count is not")
        XCTAssertEqual(usage.cost, 12.0, accuracy: 0.0001)
    }

    // MARK: - A later record for the same message id

    /// Claude Code writes 2–4 `type: assistant` lines for one response, all under the
    /// same `message.id`: the first carries a provisional usage (`output_tokens: 2`, no
    /// thinking, `stop_reason: null`), the last the final counts. Keeping the first and
    /// dropping the rest threw away most of the output — measured over this machine's
    /// `~/.claude/projects/**/subagents/*.jsonl`, 5.8 M output tokens by the first-record
    /// rule against 30.6 M by the last-record one.
    private func growingRecords() -> [String] {
        [
            line(id: "msg_grow", minutesAgo: 10, model: "claude-sonnet-4-5",
                 input: 1_000_000, output: 2, thinking: 0),
            line(id: "msg_grow", minutesAgo: 10, model: "claude-sonnet-4-5",
                 input: 1_000_000, output: 100_000, thinking: 40_000),
            line(id: "msg_grow", minutesAgo: 10, model: "claude-sonnet-4-5",
                 input: 1_000_000, output: 280_000, thinking: 149_000),
        ]
    }

    func testTheLastRecordForAMessageIdSuppliesTheTurnsCounts() async throws {
        try write(growingRecords(), project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1, "one response is one turn, however many lines log it")
        XCTAssertEqual(usage.breakdown.output, 280_000, "the final count, not the provisional 2")
        XCTAssertEqual(usage.breakdown.thinking, 149_000)
        XCTAssertEqual(usage.breakdown.input, 1_000_000, "counted once, not once per line")
        XCTAssertEqual(usage.tokens, 1_280_000)
        // $3.00 of input + $4.20 of output — the dollars follow the replaced counts.
        XCTAssertEqual(usage.cost, 7.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(usage.breakdown.cost).total, usage.cost, accuracy: 1e-9)
    }

    func testALaterRecordWithSmallerOutputDoesNotRegressTheTurn() async throws {
        // A replayed tail or a forked session can put an early record after a late one.
        // The rule is "later reading", not "last line seen".
        try write(growingRecords().reversed(), project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.output, 280_000, "a smaller later record must not shrink the turn")
        XCTAssertEqual(usage.breakdown.thinking, 149_000)
    }

    func testAReplacementAcrossPollsSurvivesTheCacheRoundTrip() async throws {
        // The provisional line is ingested, cached and the process restarts; the final
        // line arrives afterwards. The id is known from the restored `seenMessageIDs`,
        // so the replacement only works if the id→turn index is rebuilt on cache load.
        try write([growingRecords()[0]], project: alphaSlug)
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await first.refresh()
        let provisional = await first.usage(from: now.addingTimeInterval(-3600), to: now)
        XCTAssertEqual(provisional.breakdown.output, 2)

        try append(growingRecords()[2] + "\n", project: alphaSlug)
        let second = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await second.refresh()
        let updated = await second.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(updated.turns, 1, "still one turn")
        XCTAssertEqual(updated.breakdown.output, 280_000)
        XCTAssertEqual(updated.breakdown.thinking, 149_000)

        // And the replacement itself was persisted: a third launch reads no transcript.
        let third = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0)
        await third.refresh()
        let parsed = await third.filesParsedInLastScan
        let restored = await third.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(parsed, 0, "the cache answers without reopening the transcript")
        XCTAssertEqual(restored.breakdown.output, 280_000)
        XCTAssertEqual(restored.breakdown.thinking, 149_000)
    }

    // MARK: - cache_creation without the TTL object

    /// A line carrying only the aggregate `cache_creation_input_tokens`, with no nested
    /// `cache_creation` object to split it by TTL.
    private func aggregateCacheLine(id: String, minutesAgo: Double, cacheCreation: Int) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"\(id)","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation_input_tokens":\(cacheCreation)}}}
        """
    }

    func testAnAggregateCacheCreationCountIsBilledAsAFiveMinuteWrite() async throws {
        // Without the TTL object there is nothing to say which tier the write was on.
        // Dropping it lost real, chargeable tokens; 5m is what Claude Code writes unless
        // a caller opts into the 1-hour cache, and it is the cheaper of the two rates,
        // so an unknown TTL is never billed at the dearer one.
        try write([aggregateCacheLine(id: "msg_agg", minutesAgo: 10, cacheCreation: 400_000)],
                  project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.breakdown.cacheWrite5m, 400_000)
        XCTAssertEqual(usage.breakdown.cacheWrite1h, 0, "the TTL is unknown, not one hour")
        XCTAssertEqual(usage.tokens, 1_400_000)
        // $3.00 of input + 400k at Sonnet's $3.75/M 5-minute write rate.
        XCTAssertEqual(usage.cost, 4.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(usage.breakdown.cost).cacheWrite, 1.5, accuracy: 1e-9)
    }

    func testTheTTLObjectWinsOverTheAggregateWhenBothArePresent() async throws {
        // Real lines carry both, and the nested object is the one that says which tier
        // the tokens were written at. Adding the aggregate on top would double them.
        let ts = Self.iso.string(from: now.addingTimeInterval(-600))
        let both = """
        {"type":"assistant","timestamp":"\(ts)","message":{"id":"msg_both","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation_input_tokens":52467,\
        "cache_creation":{"ephemeral_5m_input_tokens":45678,"ephemeral_1h_input_tokens":6789}}}}
        """
        try write([both], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.breakdown.cacheWrite5m, 45_678)
        XCTAssertEqual(usage.breakdown.cacheWrite1h, 6_789)
        XCTAssertEqual(usage.breakdown.cacheWrite, 52_467, "counted once, at its own TTLs")
    }

    // MARK: - Aggregated token breakdown

    /// Two turns a few seconds old — not ten minutes, which falls into yesterday
    /// whenever the suite runs just after midnight.
    private func writeTodayBreakdownFixture() throws {
        try write([
            line(
                id: "msg_t1", minutesAgo: 0.1, model: "claude-sonnet-4-5",
                input: 1_000_000, output: 200_000, cacheRead: 500_000,
                cacheCreate5m: 100_000, cacheCreate1h: 10_000, thinking: 50_000
            ),
            line(
                id: "msg_t2", minutesAgo: 0.1, model: "claude-opus-4-5",
                input: 2_000_000, output: 100_000
            ),
        ], project: alphaSlug)
    }

    func testTodaysTokensAreSplitByKind() async throws {
        try writeTodayBreakdownFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let b = await aggregator.breakdown()

        XCTAssertEqual(b.todayTokenBreakdown.input, 3_000_000)
        XCTAssertEqual(b.todayTokenBreakdown.output, 300_000)
        XCTAssertEqual(b.todayTokenBreakdown.cacheRead, 500_000)
        XCTAssertEqual(b.todayTokenBreakdown.cacheWrite5m, 100_000)
        XCTAssertEqual(b.todayTokenBreakdown.cacheWrite1h, 10_000)
        XCTAssertEqual(b.todayTokenBreakdown.cacheWrite, 110_000)
        XCTAssertEqual(b.todayTokenBreakdown.thinking, 50_000, "reported, and only reported")
        XCTAssertEqual(b.todayTokens, b.todayTokenBreakdown.total, "the headline is the split's sum")
        // Sonnet: $3.00 in + $3.00 out + $0.15 cache read + $0.375 5m + $0.06 1h = $6.585
        // Opus:   $10.00 in + $2.50 out = $12.50
        XCTAssertEqual(b.todayCost, 19.085, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b.todayTokenBreakdown.cost).total, b.todayCost, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(b.todayTokenBreakdown.cost).cacheWrite, 0.435, accuracy: 1e-9)
    }

    func testEachOfTodaysModelsCarriesItsOwnSplit() async throws {
        try writeTodayBreakdownFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let b = await aggregator.breakdown()

        XCTAssertEqual(b.byModelToday.map(\.model), ["Opus 4.5", "Sonnet 4.5"], "ranked by cost")
        XCTAssertEqual(b.byModelToday[0].breakdown.input, 2_000_000)
        XCTAssertEqual(b.byModelToday[0].breakdown.cacheRead, 0)
        XCTAssertEqual(b.byModelToday[0].breakdown.thinking, 0, "no output_tokens_details in that line")
        XCTAssertEqual(b.byModelToday[0].breakdown.total, b.byModelToday[0].tokens)
        XCTAssertEqual(b.byModelToday[1].breakdown.cacheWrite, 110_000)
        XCTAssertEqual(b.byModelToday[1].breakdown.thinking, 50_000)
        XCTAssertEqual(
            try XCTUnwrap(b.byModelToday[1].breakdown.cost).total,
            b.byModelToday[1].cost,
            accuracy: 1e-9
        )
    }

    func testEachDailyRowCarriesTheSplitBehindItsTotal() async throws {
        try writeTodayBreakdownFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let b = await aggregator.breakdown()
        let day = try XCTUnwrap(b.daily.last)

        XCTAssertEqual(day.tokens.input, 3_000_000)
        XCTAssertEqual(day.tokens.cacheWrite, 110_000)
        XCTAssertEqual(day.tokens.thinking, 50_000)
        XCTAssertEqual(day.totalTokens, day.tokens.total)
        XCTAssertEqual(try XCTUnwrap(day.tokens.cost).total, day.totalCost, accuracy: 1e-9)
    }

    func testTheWindowCarriesTheSameSplit() async throws {
        try writeTodayBreakdownFixture()
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)

        XCTAssertEqual(usage.breakdown.input, 3_000_000)
        XCTAssertEqual(usage.breakdown.cacheRead, 500_000)
        XCTAssertEqual(usage.breakdown.cacheWrite, 110_000)
        XCTAssertEqual(usage.breakdown.total, usage.tokens)
        XCTAssertEqual(try XCTUnwrap(usage.breakdown.cost).total, usage.cost, accuracy: 1e-9)
        XCTAssertEqual(usage.models.map(\.model), ["Opus 4.5", "Sonnet 4.5"])
        XCTAssertEqual(usage.models[0].breakdown.input, 2_000_000)
        XCTAssertEqual(usage.models[1].breakdown.thinking, 50_000)
    }
}
