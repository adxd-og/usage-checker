import XCTest
@testable import Omelette

/// Independent verification of issue #10's fix (spec
/// `docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md` § Design #10, § Packages
/// P1): a Claude Code turn older than `recentWindow` (31 days) is no longer folded on
/// its first, provisional log line. It is held in `ingest`'s `pendingOld` until the
/// file's records are exhausted, takes a later record's counters only when that
/// record's `output_tokens` is strictly larger (`laterReading`'s rule, shared with the
/// recent path), and is applied to its chat and folded into its day exactly once, with
/// its best counters.
///
/// Fixtures are minimal but real-shaped `type: assistant` lines — the fields
/// `JSONLAggregator.parseTurn` actually reads (`message.id`, `message.model`,
/// `message.usage.*`, top-level `sessionId`, `timestamp`) — at `claude-sonnet-4-5`
/// rates ($15/M output, the only rate these fixtures exercise). Written independently
/// of the executor's `JSONLDeferredFoldTests.swift`, never touching it.
final class JSONLDeferredFoldVerificationTests: XCTestCase {
    private var root: URL!

    private let alphaSlug = "-Users-verifier-Projects-alpha"
    private let sessionA = "aaaaaaaa-1111-1111-1111-111111111111"

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLDeferredFoldVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Time

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

    // MARK: - Fixtures

    /// A minimal `type: assistant` line: exactly the fields `parseTurn` reads.
    private func line(id: String, at date: Date, output: Int, session: String = "") -> String {
        """
        {"type":"assistant","timestamp":"\(Self.iso.string(from: date))","sessionId":"\(session)",\
        "message":{"id":"\(id)","model":"claude-sonnet-4-5",\
        "usage":{"input_tokens":0,"output_tokens":\(output),"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
    }

    private func write(_ lines: [String], file: String = "session.jsonl") throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8
        )
    }

    /// $15/M output at `claude-sonnet-4-5`, the only rate these fixtures spend money on.
    private func outputCost(_ output: Int) -> Double { Double(output) * 15.0 / 1_000_000 }

    private func aggregator() -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: nil, calendar: calendar)
    }

    // MARK: - A duplicated id, 40 days old: provisional then final

    func testAnOldTurnLoggedTwiceCountsTheLaterLargerOutputInItsDayAndItsChat() async throws {
        let day = at(daysAgo: 40, hour: 12)
        try write([
            line(id: "msg_dup", at: day, output: 2, session: sessionA),
            line(id: "msg_dup", at: day.addingTimeInterval(1.5), output: 2_000, session: sessionA),
        ])

        let agg = aggregator()
        await agg.refresh()
        let daily = await agg.breakdown().daily
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.turns, 1, "one response, one turn — not two")
        XCTAssertEqual(daily.first?.totalCost ?? 0, outputCost(2_000), accuracy: 1e-9, "the final line's output, not the provisional 2")

        let chat = try XCTUnwrap(sessions.first { $0.id == sessionA })
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.tokens.output, 2_000, "the chat sum must agree with the day sum")
        XCTAssertEqual(chat.tokens.cost?.total ?? 0, outputCost(2_000), accuracy: 1e-9)
    }

    // MARK: - Three lines: equal does not replace, larger does

    func testThreeLinesSevenSevenTwoOhEightSettleOnTwoOhEight() async throws {
        let day = at(daysAgo: 40, hour: 9)
        try write([
            line(id: "msg_three", at: day, output: 7, session: sessionA),
            line(id: "msg_three", at: day.addingTimeInterval(1), output: 7, session: sessionA),
            line(id: "msg_three", at: day.addingTimeInterval(2), output: 208, session: sessionA),
        ])

        let agg = aggregator()
        await agg.refresh()
        let daily = await agg.breakdown().daily

        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily.first?.turns, 1, "three lines of one id are one turn")
        XCTAssertEqual(daily.first?.totalCost ?? 0, outputCost(208), accuracy: 1e-9)
    }

    /// The equal-output middle line must not be mistaken for "later" and silently
    /// re-stamp the turn — `laterReading` only replaces on strictly greater output.
    func testAnEqualOutputRepeatDoesNotResetTheStoredTurn() async throws {
        let day = at(daysAgo: 40, hour: 9)
        try write([
            line(id: "msg_equal", at: day, output: 500, session: sessionA),
            line(id: "msg_equal", at: day.addingTimeInterval(1), output: 500, session: sessionA),
        ])

        let agg = aggregator()
        await agg.refresh()
        let daily = await agg.breakdown().daily

        XCTAssertEqual(daily.first?.turns, 1)
        XCTAssertEqual(daily.first?.totalCost ?? 0, outputCost(500), accuracy: 1e-9)
    }

    // MARK: - Final line logged before its provisional duplicate

    func testAFinalLineLoggedBeforeTheProvisionalOneIsNotShrunk() async throws {
        let day = at(daysAgo: 40, hour: 14)
        try write([
            line(id: "msg_reorder", at: day, output: 208, session: sessionA),
            // A re-scanned tail or a forked replay putting the provisional record
            // second must not shrink what is already stored.
            line(id: "msg_reorder", at: day.addingTimeInterval(1), output: 2, session: sessionA),
        ])

        let agg = aggregator()
        await agg.refresh()
        let daily = await agg.breakdown().daily

        XCTAssertEqual(daily.first?.turns, 1)
        XCTAssertEqual(
            daily.first?.totalCost ?? 0, outputCost(208), accuracy: 1e-9,
            "a smaller later record must not overwrite the larger stored one"
        )
    }

    // MARK: - Old and recent interleaved in one file

    func testOldAndRecentTurnsInOneFileNeitherIsLostNorDoubled() async throws {
        let recentAt = at(daysAgo: 5, hour: 10)
        let oldAt = at(daysAgo: 45, hour: 10)
        // Interleaved on disk: old record first, recent second, then another old one —
        // not grouped by age, the way a real transcript never is either.
        try write([
            line(id: "msg_old", at: oldAt, output: 300, session: sessionA),
            line(id: "msg_recent", at: recentAt, output: 100, session: sessionA),
        ])

        let agg = aggregator()
        await agg.refresh()

        let recentWindowUsage = await agg.usage(
            from: now.addingTimeInterval(-10 * 24 * 3600), to: now
        )
        let oldWindowUsage = await agg.usage(
            from: now.addingTimeInterval(-50 * 24 * 3600), to: now.addingTimeInterval(-40 * 24 * 3600)
        )
        let daily = await agg.breakdown().daily
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        XCTAssertEqual(recentWindowUsage.turns, 1, "only the recent turn is a per-turn window hit")
        XCTAssertEqual(recentWindowUsage.cost, outputCost(100), accuracy: 1e-9)
        XCTAssertEqual(oldWindowUsage.turns, 0, "a folded turn never re-appears in usage(from:to:)")

        // breakdown().daily merges oldDays with a live per-day roll-up of recentTurns,
        // so both days appear — the old (folded) one and the recent (still-live) one —
        // each with exactly its own turn, never doubled onto the other.
        XCTAssertEqual(daily.count, 2, "the old turn's day and the recent turn's day both appear")
        let oldDay = try XCTUnwrap(daily.first { $0.day == calendar.startOfDay(for: oldAt) })
        let recentDay = try XCTUnwrap(daily.first { $0.day == calendar.startOfDay(for: recentAt) })
        XCTAssertEqual(oldDay.turns, 1)
        XCTAssertEqual(oldDay.totalCost, outputCost(300), accuracy: 1e-9)
        XCTAssertEqual(recentDay.turns, 1)
        XCTAssertEqual(recentDay.totalCost, outputCost(100), accuracy: 1e-9)

        let chat = try XCTUnwrap(sessions.first { $0.id == sessionA })
        XCTAssertEqual(chat.turns, 2, "both turns belong to the chat, exactly once each")
        XCTAssertEqual(
            chat.tokens.cost?.total ?? 0, outputCost(300) + outputCost(100), accuracy: 1e-9,
            "no double counting across the recent path and the deferred-fold path"
        )
    }

    /// A rescan of the same bytes (nothing new on disk) must not fold the old turn a
    /// second time.
    func testARescanOfAnUnchangedOldTranscriptDoesNotDoubleCountTheFold() async throws {
        let day = at(daysAgo: 40, hour: 12)
        try write([line(id: "msg_stable", at: day, output: 1_000, session: sessionA)])

        let agg = aggregator()
        await agg.refresh()
        await agg.refresh()
        let daily = await agg.breakdown().daily
        let sessions = await agg.sessions(from: now.addingTimeInterval(-100 * 24 * 3600), to: now)

        XCTAssertEqual(daily.first?.turns, 1)
        XCTAssertEqual(daily.first?.totalCost ?? 0, outputCost(1_000), accuracy: 1e-9)
        XCTAssertEqual(sessions.first { $0.id == sessionA }?.turns, 1)
    }
}
