import XCTest
@testable import Omelette

/// Independent verification of `JSONLAggregator`'s half of the year-retention design:
/// the 366-day mtime window and `dayRetention`, the untouched 31-day `recentWindow`,
/// the untouched 92-day `sessionWindow`, and the `cacheVersion` 5 → 6 bump. Written
/// from the spec and the diff, with its own fixtures and temp directory — never the
/// executor's test file.
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Facts, § Retention, § Claude cache, § Tests.
final class ClaudeYearRetentionVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let alphaSlug = "-Users-verifier-Projects-alpha"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeYearRetentionVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheFile(named: "v5"))
        try? FileManager.default.removeItem(at: cacheFile(named: "v6"))
    }

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

    /// An assistant turn line. `sessionId` is only needed by the session-window test
    /// below; every other test leaves it empty, matching the rest of the fixture.
    private func line(
        id: String, minutesAgo: Double, model: String, input: Int, sessionId: String = ""
    ) -> String {
        let ts = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(ts)","sessionId":"\(sessionId)",\
        "message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    private func write(_ lines: [String], project: String, file: String = "session.jsonl") throws -> URL {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - mtimeWindow / dayRetention: a year of day totals

    /// Both the mtime and the turn timestamp are ~300 days old — the shape a user on
    /// `cleanupPeriodDays: 365` actually has on disk. The design's `mtimeWindow` is
    /// 366 days, so the scanner must still open the file, and `dayRetention` (also
    /// 366 days) must still keep the day.
    func testATranscriptAboutTenMonthsOldIsReadAndItsDayAppears() async throws {
        let daysAgo = 300.0
        let file = try write([
            line(id: "msg_300d", minutesAgo: daysAgo * 24 * 60, model: "claude-sonnet-4-5", input: 2_000_000),
        ], project: alphaSlug)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 24 * 3600)],
            ofItemAtPath: file.path
        )

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let parsed = await aggregator.filesParsedInLastScan
        let daily = await aggregator.breakdown().daily
        let expectedDay = Calendar.current.startOfDay(for: now.addingTimeInterval(-daysAgo * 24 * 3600))

        XCTAssertEqual(parsed, 1, "a 300-day-old file is still inside the 366-day mtime window")
        XCTAssertEqual(daily.map(\.day), [expectedDay])
        XCTAssertEqual(daily.first?.totalCost ?? 0, 6.0, accuracy: 0.0001, "2,000,000 input @ $3/M")
    }

    /// The mirror case: a transcript ~400 days old, past both `mtimeWindow` and
    /// `dayRetention`. It must be marked consumed without ever being opened, and its
    /// day must not appear anywhere in `daily`.
    func testATranscriptAboutThirteenMonthsOldIsNeverReadAndItsDayIsAbsent() async throws {
        let daysAgo = 400.0
        let file = try write([
            line(id: "msg_400d", minutesAgo: daysAgo * 24 * 60, model: "claude-sonnet-4-5", input: 2_000_000),
        ], project: alphaSlug)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 24 * 3600)],
            ofItemAtPath: file.path
        )

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let parsed = await aggregator.filesParsedInLastScan
        let daily = await aggregator.breakdown().daily

        XCTAssertEqual(parsed, 0, "past the 366-day mtime window the file must never be opened")
        XCTAssertTrue(daily.isEmpty, "a day that was never read must not appear in the figures")
    }

    // MARK: - recentWindow: still 31 days for the rolling figures

    /// A turn 40 days old is folded into `oldDays` at ingest (past `recentWindow`), so
    /// its day total survives in `breakdown().daily` — that is the whole point of the
    /// package — but it must NOT reappear in a per-turn window query: `usage(from:to:)`
    /// only ever walks `recentTurns`, and a folded turn is not one of them. A widened
    /// `recentWindow` (accidentally tied to the new 366-day retention) would make this
    /// turn show up in `usage()` too, and this test is what would catch that.
    func testATurnPastTheThirtyOneDayRecentWindowIsFoldedOutOfTheRecentFigures() async throws {
        let daysAgo = 40.0
        try write([
            line(id: "msg_40d", minutesAgo: daysAgo * 24 * 60, model: "claude-sonnet-4-5", input: 1_000_000),
        ], project: alphaSlug)

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        // A window that comfortably covers the turn's actual timestamp.
        let usage = await aggregator.usage(from: now.addingTimeInterval(-45 * 24 * 3600), to: now)

        XCTAssertEqual(daily.count, 1, "the day total itself must survive the fold")
        XCTAssertEqual(daily.first?.totalCost ?? 0, 3.0, accuracy: 0.0001)
        XCTAssertEqual(usage.turns, 0, "recentWindow is still 31 days: a 40-day-old turn is not 'recent'")
        XCTAssertEqual(usage.cost, 0, accuracy: 1e-9)
    }

    // MARK: - sessionWindow: still 92 days for the Sessions list

    /// A chat whose last turn is 90 days old (well inside the 92-day session window)
    /// must still be listed; one whose last turn is 95 days old (well past it) must
    /// not be, whatever `dayRetention` or `mtimeWindow` now say about day totals. Both
    /// files are new, so the mtime window lets both through — only `sessionWindow`
    /// decides.
    func testAChatNinetyDaysOldIsKeptAndOneNinetyFiveDaysOldIsDropped() async throws {
        let keptSession = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let droppedSession = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        try write([
            line(
                id: "msg_kept", minutesAgo: 90 * 24 * 60, model: "claude-sonnet-4-5",
                input: 1_000_000, sessionId: keptSession
            ),
        ], project: alphaSlug, file: "kept.jsonl")
        try write([
            line(
                id: "msg_dropped", minutesAgo: 95 * 24 * 60, model: "claude-sonnet-4-5",
                input: 1_000_000, sessionId: droppedSession
            ),
        ], project: alphaSlug, file: "dropped.jsonl")

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil)
        await aggregator.refresh()
        let sessions = await aggregator.sessions(from: now.addingTimeInterval(-200 * 24 * 3600), to: now)

        XCTAssertTrue(sessions.contains { $0.id == keptSession }, "90 days is inside the 92-day session window")
        XCTAssertFalse(sessions.contains { $0.id == droppedSession }, "95 days is past the 92-day session window")
    }

    // MARK: - cacheVersion 5 → 6

    /// A v5 snapshot — the shape written before the retention fix, whose fold marks
    /// files "consumed" up to only 90 days back — must be rejected wholesale and the
    /// logs rescanned, never partially trusted. A v6 snapshot with the identical bytes
    /// must round-trip. Independent fabricated numbers from the executor's own test,
    /// so a bug that only shows up with a particular magic number cannot hide behind
    /// both suites using the same one.
    func testAVersionFiveCacheIsDiscardedAndAVersionSixCacheRoundTrips() async throws {
        try write([
            line(id: "msg_current", minutesAgo: 60, model: "claude-sonnet-4-5", input: 2_000_000),
        ], project: alphaSlug)

        let fabricatedDay = ISO8601DateFormatter().string(
            from: Calendar.current.startOfDay(for: now.addingTimeInterval(-50 * 24 * 3600))
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
                    "cost": 42.0,
                    "tokens": 999,
                    "breakdown": [
                        "input": 999, "output": 0, "cacheRead": 0,
                        "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
                    ],
                    "turns": 3,
                    "byFamily": ["opus": 42.0],
                ]],
                "seenMessageIDs": [Any](),
                "sessions": [String: Any](),
                "titles": [String: Any](),
                "firstPrompts": [String: Any](),
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        let v5URL = cacheFile(named: "v5")
        try snapshot(version: 5).write(to: v5URL)
        let stale = JSONLAggregator(rootURL: root, cacheURL: v5URL)
        await stale.refresh()
        let staleParsed = await stale.filesParsedInLastScan
        let staleDaily = await stale.breakdown().daily

        XCTAssertEqual(staleParsed, 1, "a version-5 snapshot is discarded; the one real transcript is rescanned")
        XCTAssertFalse(
            staleDaily.contains { $0.turns == 3 && $0.totalCost == 42.0 },
            "the fabricated day from a v5 snapshot must not survive"
        )

        let v6URL = cacheFile(named: "v6")
        try snapshot(version: 6).write(to: v6URL)
        let current = JSONLAggregator(rootURL: root, cacheURL: v6URL)
        await current.refresh()
        let currentDaily = await current.breakdown().daily

        XCTAssertTrue(
            currentDaily.contains { $0.turns == 3 && $0.totalCost == 42.0 },
            "a version-6 snapshot with identical bytes must round-trip its fabricated day"
        )
    }
}
