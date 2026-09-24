import XCTest
@testable import Omelette

/// Independent verification of the `cacheVersion` 6 → 7 migration (spec
/// `docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md` § Design #10, amendment
/// 2026-09-24: a v6 snapshot's `oldDays` AND its chats are kept across the bump, each
/// cleared the first time the re-scan touches it, so a day or a chat no surviving
/// transcript covers keeps its previous (low) totals instead of being lost).
///
/// Fixtures are hand-built `CostCacheSnapshot`-shaped JSON via `JSONSerialization` —
/// the type itself is private to `JSONLAggregator` — following the same schema the
/// existing suite's fixtures use (`ClaudeYearRetentionVerificationTests`,
/// `JSONLSessionsTests`). Written independently, never touching the executor's
/// `JSONLDeferredFoldTests.swift` or its cache fixtures.
final class JSONLCacheV7MigrationVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let alphaSlug = "-Users-verifier-Projects-alpha"

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLCacheV7MigrationVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheFile(named: "v6"))
        try? FileManager.default.removeItem(at: cacheFile(named: "v5"))
        try? FileManager.default.removeItem(at: cacheFile(named: "otherroot"))
        try? FileManager.default.removeItem(at: cacheFile(named: "onlyfirst"))
    }

    private func cacheFile(named name: String) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name).json")
    }

    // MARK: - Time / fixtures

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func dayStart(daysAgo: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    private func at(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: dayStart(daysAgo: daysAgo))!
    }

    private func line(id: String, at date: Date, output: Int, session: String = "") -> String {
        """
        {"type":"assistant","timestamp":"\(Self.iso.string(from: date))","sessionId":"\(session)",\
        "message":{"id":"\(id)","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":0,"output_tokens":\(output),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    private func write(_ lines: [String], file: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8
        )
    }

    /// Appends raw bytes to an existing transcript, the way a live Claude Code process
    /// would grow the file between two polls — never rewriting what is already there.
    private func append(_ lines: [String], to file: String) throws {
        let url = root.appendingPathComponent(alphaSlug, isDirectory: true).appendingPathComponent(file)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    private func outputCost(_ output: Int) -> Double { Double(output) * 15.0 / 1_000_000 }

    private func zeroTokens(_ total: Int) -> [String: Any] {
        ["input": total, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0]
    }

    /// A `CostCacheSnapshot`-shaped fixture. `oldDayEntries` and `sessionEntries` are
    /// pre-built JSON fragments so each test can fabricate exactly the stale totals it
    /// needs.
    private func snapshotData(
        version: Int,
        root snapshotRoot: URL,
        oldDayEntries: [[String: Any]] = [],
        sessionEntries: [String: Any] = [:],
        titleEntries: [String: String] = [:]
    ) -> Data {
        let object: [String: Any] = [
            "version": version,
            "root": snapshotRoot.path,
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": oldDayEntries,
            "seenMessageIDs": [Any](),
            "sessions": sessionEntries,
            "titles": titleEntries,
            "firstPrompts": [String: Any](),
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func fabricatedDay(daysAgo: Int, cost: Double, turns: Int) -> [String: Any] {
        [
            "day": ISO8601DateFormatter().string(from: dayStart(daysAgo: daysAgo)),
            "cost": cost,
            "tokens": turns * 100,
            "breakdown": zeroTokens(turns * 100),
            "turns": turns,
            "byFamily": ["opus": cost],
        ]
    }

    private func fabricatedSession(
        daysAgo: Int, turns: Int, projectSlug: String = "-Users-verifier-Projects-alpha"
    ) -> [String: Any] {
        let at = self.at(daysAgo: daysAgo, hour: 9)
        let tokens = zeroTokens(turns * 100)
        return [
            "projectSlug": projectSlug,
            "firstAt": ISO8601DateFormatter().string(from: at),
            "lastAt": ISO8601DateFormatter().string(from: at),
            "days": [[
                "day": ISO8601DateFormatter().string(from: dayStart(daysAgo: daysAgo)),
                "turns": turns,
                "tokens": tokens,
                "mainTokens": tokens,
            ]],
            "agents": [String: Any](),
            "byModel": [String: Any](),
        ]
    }

    private func aggregator(cache: URL) -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cache, calendar: calendar)
    }

    // MARK: - A day no surviving transcript covers

    func testAV6DayNoTranscriptCoversSurvivesAndTheCacheIsRewrittenAsV7() async throws {
        // One unrelated, recent transcript, so the migration scan has something to do
        // without ever touching day D.
        try write([line(id: "msg_recent", at: now.addingTimeInterval(-2 * 3600), output: 10, session: "s-recent")],
                   file: "session.jsonl")

        let cacheURL = cacheFile(named: "onlyfirst")
        try snapshotData(
            version: 6, root: root,
            oldDayEntries: [fabricatedDay(daysAgo: 40, cost: 42.0, turns: 3)]
        ).write(to: cacheURL)

        let first = aggregator(cache: cacheURL)
        await first.refresh()
        let firstDaily = await first.breakdown().daily
        let firstParsed = await first.filesParsedInLastScan

        let day40 = try XCTUnwrap(firstDaily.first { $0.day == dayStart(daysAgo: 40) })
        XCTAssertEqual(day40.turns, 3, "no surviving transcript touches this day; its old total is kept whole")
        XCTAssertEqual(day40.totalCost, 42.0, accuracy: 1e-9)
        XCTAssertEqual(firstParsed, 1, "the one recent transcript is read on the migration scan")

        // The persisted file must carry the new version number.
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, 8, "the migrated snapshot is saved back at the current version, 8")

        // A relaunch: a fresh aggregator instance over the same cache and log root.
        let second = aggregator(cache: cacheURL)
        await second.refresh()
        let secondParsed = await second.filesParsedInLastScan
        let secondDaily = await second.breakdown().daily

        XCTAssertEqual(secondParsed, 0, "a relaunch re-reads nothing more: the v7 cache's file marks are trusted")
        let day40Again = try XCTUnwrap(secondDaily.first { $0.day == dayStart(daysAgo: 40) })
        XCTAssertEqual(day40Again.turns, 3)
        XCTAssertEqual(day40Again.totalCost, 42.0, accuracy: 1e-9, "the kept day survives the v7 round trip too")
    }

    // MARK: - A day a surviving transcript covers

    func testAV6DayASurvivingTranscriptCoversIsRebuiltNotDoubled() async throws {
        let day = at(daysAgo: 40, hour: 8)
        let sessionID = "bbbbbbbb-2222-2222-2222-222222222222"
        // Two transcripts land on the same old day.
        try write([line(id: "msg_one", at: day, output: 100, session: sessionID)], file: "one.jsonl")
        try write(
            [line(id: "msg_two", at: day.addingTimeInterval(3600), output: 50, session: sessionID)],
            file: "two.jsonl"
        )

        let cacheURL = cacheFile(named: "onlyfirst")
        // A wildly wrong stale total on disk: if it were added to instead of replaced,
        // the day would show 999 + 150 turns / a huge cost instead of the fresh sum.
        try snapshotData(
            version: 6, root: root,
            oldDayEntries: [fabricatedDay(daysAgo: 40, cost: 999.0, turns: 50)],
            sessionEntries: [sessionID: fabricatedSession(daysAgo: 40, turns: 99)]
        ).write(to: cacheURL)

        let agg = aggregator(cache: cacheURL)
        await agg.refresh()
        let daily = await agg.breakdown().daily
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        let day40 = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        XCTAssertEqual(day40.turns, 2, "rebuilt from the two surviving transcripts, not added onto the stale 50")
        XCTAssertEqual(day40.totalCost, outputCost(100) + outputCost(50), accuracy: 1e-9)

        let chat = try XCTUnwrap(sessions.first { $0.id == sessionID })
        XCTAssertEqual(chat.turns, 2, "the chat is rebuilt too, not left at the stale 99")
        XCTAssertEqual(
            chat.tokens.cost?.total ?? 0, day40.totalCost, accuracy: 1e-9,
            "the chat sum agrees with the day sum"
        )
    }

    // MARK: - Chats: one gone, one rebuilt

    func testAV6ChatWithNoSurvivingTranscriptIsKeptAndOneWithOneIsRebuilt() async throws {
        let goneChat = "cccccccc-3333-3333-3333-333333333333"
        let survivingChat = "dddddddd-4444-4444-4444-444444444444"
        // Only survivingChat has a transcript on disk.
        try write(
            [line(id: "msg_survivor", at: at(daysAgo: 40, hour: 10), output: 500, session: survivingChat)],
            file: "survivor.jsonl"
        )

        let cacheURL = cacheFile(named: "onlyfirst")
        try snapshotData(
            version: 6, root: root,
            sessionEntries: [
                goneChat: fabricatedSession(daysAgo: 40, turns: 10),
                survivingChat: fabricatedSession(daysAgo: 40, turns: 77),
            ],
            titleEntries: [goneChat: "A chat whose transcript is gone"]
        ).write(to: cacheURL)

        let agg = aggregator(cache: cacheURL)
        await agg.refresh()
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        let gone = try XCTUnwrap(sessions.first { $0.id == goneChat })
        XCTAssertEqual(gone.turns, 10, "kept exactly as the v6 cache had it — nothing left to rebuild it from")
        XCTAssertEqual(gone.title, "A chat whose transcript is gone", "its name survives the bump too")

        let survivor = try XCTUnwrap(sessions.first { $0.id == survivingChat })
        XCTAssertEqual(survivor.turns, 1, "rebuilt from its one surviving turn, not 77 + 1 or left at 77")
    }

    // MARK: - Older versions and other roots

    func testAV5CacheIsStillRejectedWhole() async throws {
        try write([line(id: "msg_current", at: now.addingTimeInterval(-3600), output: 100, session: "s")],
                   file: "session.jsonl")

        let cacheURL = cacheFile(named: "v5")
        try snapshotData(
            version: 5, root: root,
            oldDayEntries: [fabricatedDay(daysAgo: 40, cost: 42.0, turns: 3)]
        ).write(to: cacheURL)

        let agg = aggregator(cache: cacheURL)
        await agg.refresh()
        let daily = await agg.breakdown().daily
        let parsed = await agg.filesParsedInLastScan

        XCTAssertFalse(
            daily.contains { $0.day == dayStart(daysAgo: 40) && $0.turns == 3 },
            "only v6 is carried over; a v5 snapshot's oldDays must not survive"
        )
        XCTAssertEqual(parsed, 1, "a v5 snapshot means a full rescan, exactly as before this package")
    }

    func testAV6CacheForAnotherLogRootKeepsNothing() async throws {
        let otherRoot = root.deletingLastPathComponent().appendingPathComponent("not-\(root.lastPathComponent)")
        let cacheURL = cacheFile(named: "otherroot")
        try snapshotData(
            version: 6, root: otherRoot,
            oldDayEntries: [fabricatedDay(daysAgo: 40, cost: 42.0, turns: 3)],
            sessionEntries: ["e-1": fabricatedSession(daysAgo: 40, turns: 5)]
        ).write(to: cacheURL)

        let agg = aggregator(cache: cacheURL)
        await agg.refresh()
        let daily = await agg.breakdown().daily
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        XCTAssertTrue(daily.isEmpty, "a v6 cache written for a different log root must not be migrated")
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Only the first scan after the bump rebuilds

    func testOnlyTheFirstScanAfterTheBumpRebuildsASecondRefreshAddsInstead() async throws {
        let day = at(daysAgo: 40, hour: 8)
        let sessionID = "eeeeeeee-5555-5555-5555-555555555555"
        try write([line(id: "msg_x", at: day, output: 100, session: sessionID)], file: "grower.jsonl")

        let cacheURL = cacheFile(named: "onlyfirst")
        try snapshotData(
            version: 6, root: root,
            oldDayEntries: [fabricatedDay(daysAgo: 40, cost: 999.0, turns: 50)]
        ).write(to: cacheURL)

        let agg = aggregator(cache: cacheURL)
        await agg.refresh()
        let dailyAfterFirst = await agg.breakdown().daily
        let day40AfterFirst = try XCTUnwrap(dailyAfterFirst.first { $0.day == dayStart(daysAgo: 40) })
        XCTAssertEqual(day40AfterFirst.turns, 1, "the first scan rebuilds the day from msg_x alone")
        XCTAssertEqual(day40AfterFirst.totalCost, outputCost(100), accuracy: 1e-9)

        // A new old turn lands in the same file, in the same day, after the migration
        // scan already ran once.
        try append([line(id: "msg_y", at: day.addingTimeInterval(3600), output: 50, session: sessionID)],
                    to: "grower.jsonl")

        await agg.refresh()
        let dailyAfterSecond = await agg.breakdown().daily
        let day40AfterSecond = try XCTUnwrap(dailyAfterSecond.first { $0.day == dayStart(daysAgo: 40) })

        XCTAssertEqual(
            day40AfterSecond.turns, 2,
            "the second refresh adds msg_y to what the first refresh rebuilt, it does not clear the day again"
        )
        XCTAssertEqual(day40AfterSecond.totalCost, outputCost(100) + outputCost(50), accuracy: 1e-9)
    }
}
