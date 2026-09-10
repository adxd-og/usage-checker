import XCTest
@testable import Omelette

/// Independent verification of `JSONLAggregator`'s per-model split, against the spec
/// rather than the executor's own `JSONLSessionsTests` fixtures:
/// docs/superpowers/specs/2026-09-10-sessions-by-model-design.md § Design.
///
/// Every fixture line here is built by this file's own `rawTurn`, not by
/// `JSONLSessionsTests`'s private helpers — a verifier writes its own fixtures rather
/// than trusting the executor's.
final class SessionsByModelJSONLVerificationTests: XCTestCase {
    private var root: URL!
    private let alphaSlug = "-Users-tester-Projects-verify"
    private let sessionID = "f1e2d3c4-0000-0000-0000-000000000001"

    /// UTC throughout, so a day boundary means the same thing wherever the suite runs.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionsByModelJSONLVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: cacheFile(named: "control"))
    }

    private var cacheURL: URL { cacheFile(named: "cost-cache") }

    private func cacheFile(named name: String) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name).json")
    }

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func at(daysAgo: Int, hour: Int) -> Date {
        calendar.date(byAdding: .hour, value: hour, to: dayStart(daysAgo: daysAgo))!
    }

    private func dayStart(daysAgo: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    // MARK: - Fixture records, built independently of JSONLSessionsTests

    /// One assistant record, built with `JSONSerialization` so that `effort: nil` means
    /// the field is genuinely absent from the line rather than present-and-empty.
    private func rawTurn(
        id: String, at date: Date, model: String,
        input: Int = 0, output: Int = 0,
        effort: String?, agentID: String? = nil, agentKind: String? = nil,
        session: String? = nil
    ) -> String {
        let message: [String: Any] = [
            "model": model, "id": id, "type": "message", "role": "assistant",
            "content": [["type": "text", "text": "…"]],
            "usage": [
                "input_tokens": input, "output_tokens": output,
                "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
            ],
        ]
        var obj: [String: Any] = [
            "type": "assistant",
            "timestamp": Self.iso.string(from: date),
            "sessionId": session ?? sessionID,
            "message": message,
        ]
        if let effort { obj["effort"] = effort }
        if let agentID {
            obj["agentId"] = agentID
            obj["isSidechain"] = true
            if let agentKind { obj["attributionAgent"] = agentKind }
        }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func writeMain(_ lines: [String], session: String? = nil) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(session ?? sessionID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func writeSubagent(_ lines: [String], agentID: String, session: String? = nil) throws {
        let dir = root
            .appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(session ?? sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func aggregator(cache: URL? = nil, root: URL? = nil) -> JSONLAggregator {
        JSONLAggregator(rootURL: root ?? self.root, cacheURL: cache, saveInterval: 0, calendar: calendar)
    }

    // MARK: - Two efforts on one model plus a sub-agent on a third: exact sums

    func testTwoEffortsOnOneModelPlusASubAgentSumExactlyAcrossEveryCategory() async throws {
        try writeMain([
            rawTurn(id: "msg_1", at: at(daysAgo: 1, hour: 9), model: "claude-sonnet-4-5",
                    input: 100_000, effort: "medium"),
            rawTurn(id: "msg_2", at: at(daysAgo: 1, hour: 10), model: "claude-sonnet-4-5",
                    input: 40_000, output: 10_000, effort: "xhigh"),
        ])
        try writeSubagent(
            [rawTurn(id: "msg_3", at: at(daysAgo: 1, hour: 11), model: "claude-haiku-4-5",
                     input: 60_000, output: 4_000, effort: "low", agentID: "agent-1", agentKind: "planner")],
            agentID: "agent-1"
        )

        let agg = aggregator()
        await agg.refresh()
        let sessions = await agg.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(
            Set(chat.models.map(\.id)),
            ["claude-sonnet-4-5|medium", "claude-sonnet-4-5|xhigh", "claude-haiku-4-5|low"],
            "one model at two efforts is two rows, and the sub-agent's model is a third"
        )
        XCTAssertEqual(chat.models.count, 3)
        XCTAssertEqual(chat.turns, 3, "two main turns plus the sub-agent's")
        XCTAssertEqual(
            chat.models.reduce(0) { $0 + $1.turns }, chat.turns,
            "every turn of the chat lands in exactly one model row"
        )

        let summed = chat.models.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        XCTAssertEqual(summed.input, chat.tokens.input)
        XCTAssertEqual(summed.output, chat.tokens.output)
        XCTAssertEqual(summed.cacheRead, chat.tokens.cacheRead)
        XCTAssertEqual(summed.cacheWrite5m, chat.tokens.cacheWrite5m)
        XCTAssertEqual(summed.cacheWrite1h, chat.tokens.cacheWrite1h)
        XCTAssertEqual(summed.thinking, chat.tokens.thinking)
        XCTAssertEqual(
            try XCTUnwrap(summed.cost).total, try XCTUnwrap(chat.tokens.cost).total,
            accuracy: 1e-9, "and the dollars, category for category, sum to the session's own"
        )
        // Sanity on the actual numbers, not just "the rows add up to whatever the chat
        // says": $0.30 (medium) + $0.27 (xhigh: $0.12 in + $0.15 out) + $0.08 (haiku).
        XCTAssertEqual(try XCTUnwrap(summed.cost).total, 0.65, accuracy: 1e-9)
    }

    // MARK: - Effort absent and effort "" land in the same row

    func testARecordWithNoEffortFieldAndOneWithAnEmptyEffortShareOneRow() async throws {
        try writeMain([
            rawTurn(id: "msg_absent", at: at(daysAgo: 1, hour: 9), model: "claude-sonnet-4-5",
                    input: 1_000, effort: nil),
            rawTurn(id: "msg_empty", at: at(daysAgo: 1, hour: 10), model: "claude-sonnet-4-5",
                    input: 2_000, effort: ""),
        ])

        let agg = aggregator()
        await agg.refresh()
        let sessions = await agg.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        XCTAssertEqual(chat.models.map(\.id), ["claude-sonnet-4-5|"], "one row, not two")
        XCTAssertEqual(chat.models[0].turns, 2)
        XCTAssertEqual(chat.models[0].tokens.input, 3_000)
    }

    // MARK: - A later record: larger grows the row, smaller changes nothing

    func testALargerLaterRecordForOneMessageIdGrowsItsRowsTokensButNotItsTurns() async throws {
        try writeMain([
            rawTurn(id: "msg_grow", at: at(daysAgo: 1, hour: 10), model: "claude-haiku-4-5",
                    input: 500, output: 5, effort: "high"),
            rawTurn(id: "msg_grow", at: at(daysAgo: 1, hour: 10), model: "claude-haiku-4-5",
                    input: 500, output: 999, effort: "high"),
        ])

        let agg = aggregator()
        await agg.refresh()
        let sessions = await agg.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        let row = try XCTUnwrap(chat.models.first { $0.id == "claude-haiku-4-5|high" })
        XCTAssertEqual(row.turns, 1, "a revision moves tokens, never turns")
        XCTAssertEqual(row.tokens.output, 999, "the row took the later, larger record")
        XCTAssertEqual(row.tokens.input, 500, "counted once, not once per line")
    }

    func testASmallerLaterRecordForOneMessageIdLeavesTheRowUnchanged() async throws {
        try writeMain([
            rawTurn(id: "msg_shrink", at: at(daysAgo: 1, hour: 10), model: "claude-opus-4-5",
                    input: 700, output: 5, effort: "xhigh"),
            rawTurn(id: "msg_shrink", at: at(daysAgo: 1, hour: 10), model: "claude-opus-4-5",
                    input: 700, output: 500, effort: "xhigh"),
            // A smaller output than what is already stored: `replaceIfLater` refuses it
            // before `SessionAgg.revise` is ever reached, so the row must not move.
            rawTurn(id: "msg_shrink", at: at(daysAgo: 1, hour: 10), model: "claude-opus-4-5",
                    input: 700, output: 50, effort: "xhigh"),
        ])

        let agg = aggregator()
        await agg.refresh()
        let sessions = await agg.sessions(from: dayStart(daysAgo: 2), to: now)
        let chat = try XCTUnwrap(sessions.first)

        let row = try XCTUnwrap(chat.models.first { $0.id == "claude-opus-4-5|xhigh" })
        XCTAssertEqual(row.turns, 1)
        XCTAssertEqual(row.tokens.output, 500, "the smaller third line must not shrink the row")
    }

    // MARK: - A clipped range still reports whole-chat model rows

    func testAClippedRangeStillReportsBothModelRowsAtTheirFullWholeChatTotals() async throws {
        try writeMain([
            rawTurn(id: "msg_old", at: at(daysAgo: 2, hour: 9), model: "claude-opus-4-5",
                    input: 1_000, effort: "e1"),
            rawTurn(id: "msg_new", at: at(daysAgo: 1, hour: 9), model: "claude-haiku-4-5",
                    input: 2_000, effort: "e2"),
        ])

        let agg = aggregator()
        await agg.refresh()
        let sessions = await agg.sessions(from: dayStart(daysAgo: 1), to: now)
        let chat = try XCTUnwrap(
            sessions.first,
            "the day-1 turn keeps the chat inside the clipped range"
        )

        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 1)], "only the in-range day survives")
        XCTAssertEqual(chat.turns, 1, "and only its one turn")
        XCTAssertEqual(
            Set(chat.models.map(\.id)), ["claude-opus-4-5|e1", "claude-haiku-4-5|e2"],
            "both rows, including the one whose only day was clipped out"
        )
        XCTAssertEqual(
            chat.models.reduce(0) { $0 + $1.turns }, 2,
            "the model rows outnumber the clipped chat's own turn count"
        )
    }

    // MARK: - Cache v5 round trip after the source logs are gone

    func testModelRowsSurviveARelaunchEvenAfterTheSourceTranscriptsAreDeleted() async throws {
        try writeMain([
            rawTurn(id: "msg_a", at: at(daysAgo: 1, hour: 9), model: "claude-sonnet-4-5",
                    input: 10_000, output: 500, effort: "high"),
            rawTurn(id: "msg_b", at: at(daysAgo: 1, hour: 10), model: "claude-opus-4-5",
                    input: 20_000, output: 200, effort: "xhigh"),
        ])

        let first = aggregator(cache: cacheURL)
        await first.refresh()
        let beforeSessions = await first.sessions(from: dayStart(daysAgo: 2), to: now)
        let before = try XCTUnwrap(beforeSessions.first)
        XCTAssertEqual(before.models.count, 2, "the fixture really did produce two rows")

        // The whole log tree is gone: only the cache can answer now.
        try FileManager.default.removeItem(at: root)

        let second = aggregator(cache: cacheURL)
        await second.refresh()
        let parsed = await second.filesParsedInLastScan
        let afterSessions = await second.sessions(from: dayStart(daysAgo: 2), to: now)
        let after = try XCTUnwrap(afterSessions.first)

        XCTAssertEqual(parsed, 0, "nothing to parse — the source transcripts no longer exist")
        XCTAssertEqual(after.models.count, 2)
        XCTAssertEqual(after.models, before.models, "keys, efforts, turns and every dollar, unchanged")
    }

    // MARK: - A version-4 cache is rejected; a version-5 file with the same bytes is not

    func testAVersionFourCostCacheIsRejectedButAVersionFiveFileWithIdenticalBytesIsAccepted() async throws {
        // A small real fixture so a rejected snapshot forces a real rescan.
        try writeMain([
            rawTurn(id: "msg_real", at: at(daysAgo: 1, hour: 9), model: "claude-sonnet-4-5",
                    input: 1_000, effort: "high"),
        ])

        func snapshot(version: Int) -> Data {
            let tokens: [String: Any] = [
                "input": 42_000, "output": 0, "cacheRead": 0,
                "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
            ]
            let object: [String: Any] = [
                "version": version,
                "root": root.path,
                "savedAt": ISO8601DateFormatter().string(from: now),
                "fileMarks": [String: Any](),
                "recentTurns": [Any](),
                "oldDays": [Any](),
                "seenMessageIDs": [Any](),
                "sessions": [
                    "eeeeeeee-0000-0000-0000-000000000099": [
                        "projectSlug": alphaSlug,
                        "firstAt": ISO8601DateFormatter().string(from: at(daysAgo: 1, hour: 9)),
                        "lastAt": ISO8601DateFormatter().string(from: at(daysAgo: 1, hour: 9)),
                        "days": [[
                            "day": ISO8601DateFormatter().string(from: dayStart(daysAgo: 1)),
                            "turns": 42,
                            "tokens": tokens,
                            "mainTokens": tokens,
                        ]],
                        "agents": [String: Any](),
                        "byModel": [
                            "claude-haiku-4-5|low": [
                                "model": "claude-haiku-4-5",
                                "effort": "low",
                                "turns": 42,
                                "tokens": tokens,
                            ],
                        ],
                    ],
                ],
                "titles": ["eeeeeeee-0000-0000-0000-000000000099": "A chat only the cache remembers"],
                "firstPrompts": [String: Any](),
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        try snapshot(version: 4).write(to: cacheURL)
        let stale = aggregator(cache: cacheURL)
        await stale.refresh()
        let staleSessions = await stale.sessions(from: dayStart(daysAgo: 3), to: now)
        let staleParsed = await stale.filesParsedInLastScan

        XCTAssertEqual(staleParsed, 1, "a version-4 snapshot is discarded wholesale, forcing a rescan")
        XCTAssertFalse(
            staleSessions.contains { $0.title == "A chat only the cache remembers" },
            "nothing from the rejected snapshot may reach the session list"
        )

        let controlURL = cacheFile(named: "control")
        try snapshot(version: 5).write(to: controlURL)
        let current = aggregator(cache: controlURL)
        await current.refresh()
        let restored = await current.sessions(from: dayStart(daysAgo: 3), to: now)

        let old = try XCTUnwrap(
            restored.first { $0.title == "A chat only the cache remembers" },
            "the identical bytes at version 5 prove the version guard, not a decode failure, rejected version 4"
        )
        XCTAssertEqual(old.models.map(\.id), ["claude-haiku-4-5|low"])
        XCTAssertEqual(old.models.first?.turns, 42)
    }
}
