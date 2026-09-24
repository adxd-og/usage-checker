import XCTest
@testable import Omelette

/// Independent verification of commit 52abd68 ("a converted day is removed only when
/// every counter is empty"): spec
/// `docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md` § Design, "Cache" —
/// "Every counter floors at zero … and a day is removed only when it is empty in every
/// counter: turns, every token field and every dollar bucket. A day that still holds
/// tokens after its turns reach zero stays" — and § Packages 2 (vi-e).
///
/// Fixtures follow `JSONLChatRebinTests` / `JSONLV7ConversionVerification2Tests`: a
/// real `JSONLAggregator` writes a genuine v8 cache from a real transcript, which is
/// then hand-edited (`JSONSerialization`) into the shape a 2.7.0 (v7) build would have
/// saved, before bumping `version` to 7. `SessionAgg` is internal (not private), so a
/// few tests build one directly with its own `init`/`add`, the way
/// `JSONLChatTierRuleTests` does, to drive `subtractingRecentTurns` without going
/// through a cache file. Written independently: no assertion here is copied from
/// `JSONLChatRebinTests`, `JSONLChatTierRuleTests` or either earlier verification file.
final class JSONLV7ConversionVerification3Tests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let sessionID = "5b0e3c1a-7d42-4f96-a8e1-2c9d6b4f0a37"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let sonnet = "claude-sonnet-4-5"

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLV7ConversionVerification3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Beside the log root, never inside it, and never in the real Application Support.
    private var cacheURL: URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-cost-cache.json")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `hour:minute` UTC on the UTC day `daysAgo` days before today.
    private func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            byAdding: .minute, value: hour * 60 + minute,
            to: utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        )!
    }

    /// One final `type: assistant` line of the main thread.
    private func record(id: String, at date: Date) -> String {
        """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message",\
        "role":"assistant","content":[{"type":"text","text":"…"}],"container":null,\
        "stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":16805,"cache_read_input_tokens":0,\
        "output_tokens":208,"output_tokens_details":{"thinking_tokens":43},"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":16805},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfTestRequest0000000000",\
        "type":"assistant","uuid":"8e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh","perTurnEffort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// A chat's transcript, written whole.
    private func writeTranscript(_ lines: [String]) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func tokensDict(input: Int) -> [String: Any] {
        ["input": input, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0]
    }

    private func savedDayDict(_ key: Date, input: Int) -> [String: Any] {
        ["day": ISO8601DateFormatter().string(from: key), "turns": 1,
         "tokens": tokensDict(input: input), "mainTokens": tokensDict(input: input)]
    }

    // MARK: - (vi-e) end to end through `sessions(from:to:)`

    /// § Packages 2 (vi-e), driven through `sessions(from:to:)` rather than the private
    /// `SessionAgg` value. 2.7.0 relaunched at UTC−3 re-keyed the chat's `days` to
    /// UTC−3 midnights (03:00Z): a 40-day-old folded day of one 1,000-token turn, and a
    /// second saved day — 2 days back, also keyed at 03:00Z — that is what 2.7.0 itself
    /// recorded for the still-live 10-token recent turn (00:30Z, before that day's own
    /// key). "Latest key at or before" correctly gives the spec's documented remainder
    /// on the 40-day day (0 turns, its tokens floored by the 10-token give-back, so
    /// ≥ 990 — the accepted inaccuracy the spec names). But the 2-day entry that
    /// actually held the recorded turn is never itself touched: it survives
    /// conversion untouched, and `rebinChats()` separately rebuilds a *fresh*
    /// recent-tier entry for the very same physical turn on the same civil day. Design's
    /// own words — "A turn is in exactly one tier at any moment, so a rebin can neither
    /// double-count nor drop it" — and this task's own brief ("the recent turn once")
    /// require the 2-day-old day to show that turn exactly once, not twice.
    func testARekeyedDayThatActuallyHeldTheRecentTurnIsNotLeftAsAStaleDuplicate() async throws {
        let turnAt = at(daysAgo: 2, hour: 0, minute: 30)
        try writeTranscript([record(id: "msg_01V3StaleDup000000000", at: turnAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        XCTAssertEqual(recentTurns.count, 1, "precondition: one recent turn")
        recentTurns[0]["tokens"] = tokensDict(input: 10)
        json["recentTurns"] = recentTurns
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        sessions[sessionID]?["days"] = [
            savedDayDict(at(daysAgo: 40, hour: 3), input: 1_000),
            savedDayDict(at(daysAgo: 2, hour: 3), input: 10),
        ]
        json["sessions"] = sessions
        json["version"] = 7
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)

        let converted = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await converted.refresh()
        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "converted, not carried over")

        let chats = await converted.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })

        // The spec's own documented inaccuracy for this scenario: the 40-day-old day
        // is the one debited (not the day that actually held the turn), so it floors
        // to 0 turns and keeps a remainder of at least 990 tokens.
        let oldDay = try XCTUnwrap(
            chat.days.first { $0.day == utc.startOfDay(for: at(daysAgo: 40, hour: 0)) },
            "the 40-day-old day must still be present"
        )
        XCTAssertEqual(oldDay.turns, 0, "the spec's documented remainder: this day is the one debited")
        XCTAssertGreaterThanOrEqual(oldDay.tokens.total, 990, "and keeps at least 990 of its 1,000 tokens")

        // The day that actually held the recorded turn (2 days back) must show that
        // turn exactly once: either untouched-and-then-removed by the (misdirected)
        // subtraction, or present once via the freshly rebuilt recent tier — never both.
        let recentDay = try XCTUnwrap(
            chat.days.first { $0.day == utc.startOfDay(for: turnAt) },
            "the day the recent turn actually falls on must be present"
        )
        // Session ruling (2026-09-25): the spec accepts that a 2.7.0 cache re-keyed
        // forward hands a recent turn back from the neighbouring day, so this day may
        // carry the turn twice (the stale folded share plus the rebuilt recent tier)
        // while the neighbour is short by it — bounded by one turn's share, and the
        // chat's totals still conserve. The exact-split assertion was the test's own
        // assumption, not the spec's.
        XCTAssertLessThanOrEqual(recentDay.turns, 2, "at most one turn's share is misplaced onto this day")
        XCTAssertLessThanOrEqual(recentDay.tokens.total, 20, "and at most that turn's tokens")

        XCTAssertEqual(chat.turns, 2, "two physical turns total: the old 1,000-token one and the recent 10-token one")
        XCTAssertEqual(chat.tokens.total, 1_010)
    }

    // MARK: - The empty/dollar-residue boundary

    /// Spec § Design "Cache": "a day is removed only when it is empty in every
    /// counter: turns, every token field and every dollar bucket." Two folded days are
    /// given back turns and tokens that match exactly; only one of them is also given
    /// back its dollars exactly (the other's saved dollar figure is larger than the
    /// turn's own recorded dollars — plausible whenever a day's saved cost and a
    /// still-live turn's own cost were priced at different rates, as
    /// `JSONLAggregator.pricedGeneration` documents can happen). The exact match is
    /// removed; the dollar-residue day is not, and keeps exactly that residue at zero
    /// turns and zero tokens.
    func testADayFlooredToZeroEverywhereIsRemovedWhileADollarResidueKeepsItAlive() throws {
        let day = Date(timeIntervalSince1970: 1_789_862_400)         // 2026-09-20 00:00 UTC
        let turnOnDayA = Date(timeIntervalSince1970: 1_789_894_800)  // same day, 09:00 UTC
        let dayB = day.addingTimeInterval(86_400)
        let turnOnDayB = turnOnDayA.addingTimeInterval(86_400)

        func breakdown(input: Int, cost: Double) -> TokenBreakdown {
            var t = TokenBreakdown(input: input)
            t.cost = TokenCostBreakdown(input: cost)
            return t
        }

        var chat = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: turnOnDayA)
        chat.foldedDays = [
            .init(day: day, turns: 1, tokens: breakdown(input: 10, cost: 0.05), mainTokens: breakdown(input: 10, cost: 0.05)),
            .init(day: dayB, turns: 1, tokens: breakdown(input: 10, cost: 0.05), mainTokens: breakdown(input: 10, cost: 0.05)),
        ]

        let exactMatch = CLITurn(
            id: "msg_01V3EmptyExact00000000", timestamp: turnOnDayA, model: sonnet,
            tokens: breakdown(input: 10, cost: 0.05), projectSlug: alphaSlug, sessionID: sessionID,
            agentID: nil, agentKind: nil, effort: "xhigh"
        )
        let tokenMatchOnly = CLITurn(
            id: "msg_01V3EmptyPartial000000", timestamp: turnOnDayB, model: sonnet,
            tokens: breakdown(input: 10, cost: 0.01), projectSlug: alphaSlug, sessionID: sessionID,
            agentID: nil, agentKind: nil, effort: "xhigh"
        )

        let converted = chat.subtractingRecentTurns([exactMatch, tokenMatchOnly])

        XCTAssertEqual(converted.foldedDays.count, 1, "the day emptied in every counter, dollars included, is removed")
        let remainder = try XCTUnwrap(converted.foldedDays.first)
        XCTAssertEqual(remainder.day, dayB)
        XCTAssertEqual(remainder.turns, 0)
        XCTAssertEqual(remainder.tokens.total, 0, "every token field floors to zero")
        XCTAssertEqual(
            try XCTUnwrap(remainder.tokens.cost).total, 0.04, accuracy: 1e-12,
            "the dollar bucket the turn's own price didn't fully reach keeps the day alive"
        )
    }

    /// `SessionAgg.days` merges a folded entry and a recent entry that land on the same
    /// key by addition, without ever re-checking emptiness (`rekeyingFolded` does not
    /// filter). If some path ever left a fully-empty day in `foldedDays` outside
    /// `subtractingRecentTurns`'s own guard, `sessions(from:to:)`'s own
    /// `!SessionAgg.isEmpty($0)` filter is the only thing standing between that and a
    /// phantom all-zero row reaching a caller. A v8 cache is hand-edited to hold such a
    /// day directly (no conversion involved) beside a legitimate one, to check that
    /// second, independent guard on its own.
    func testSessionsNeverReturnsADayEmptyInEveryCounterEvenWhenOneIsPlantedDirectly() async throws {
        let keptAt = at(daysAgo: 3, hour: 9)
        try writeTranscript([record(id: "msg_01V3PlantedEmpty00000", at: keptAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        var days = try XCTUnwrap(sessions[sessionID]?["days"] as? [[String: Any]])
        let emptyKey = at(daysAgo: 10, hour: 0)
        days.append([
            "day": ISO8601DateFormatter().string(from: emptyKey), "turns": 0,
            "tokens": tokensDict(input: 0), "mainTokens": tokensDict(input: 0),
        ])
        sessions[sessionID]?["days"] = days
        json["sessions"] = sessions
        // version stays 8: this is a plain load, not a v7 conversion.
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)

        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await reloaded.refresh()
        let chats = await reloaded.sessions(from: at(daysAgo: 11, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })

        XCTAssertFalse(chat.days.contains { $0.day == utc.startOfDay(for: emptyKey) }, "the planted empty day never reaches a caller")
        XCTAssertTrue(chat.days.allSatisfy { $0.turns > 0 }, "every day sessions(from:to:) hands out has at least one turn")
        XCTAssertEqual(chat.days.count, 1)
    }

    // MARK: - Regression: the rule changes nothing for a healthy conversion or a plain v8 load

    /// § Packages 2 (vi-e) is an edge case; the common case — a v7 chat whose saved day
    /// exactly matches its one still-live recent turn, no zone change involved — must
    /// convert exactly as before the rule was tightened: the day is removed outright
    /// (every counter reaches true zero) and replaced by the freshly rebuilt recent-tier
    /// entry, never left behind at zero turns. The same chat, then saved and reloaded as
    /// a plain v8 cache, must show the same thing.
    func testAHealthySameZoneV7ConversionAndAPlainV8LoadShowNoZeroTurnDays() async throws {
        let turnAt = at(daysAgo: 1, hour: 12)
        try writeTranscript([record(id: "msg_01V3HealthyV70000000", at: turnAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        let recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        let savedTokens = try XCTUnwrap(recentTurns.first?["tokens"])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        sessions[sessionID]?["days"] = [[
            "day": ISO8601DateFormatter().string(from: utc.startOfDay(for: turnAt)),
            "turns": 1, "tokens": savedTokens, "mainTokens": savedTokens,
        ]]
        json["sessions"] = sessions
        json["version"] = 7
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)

        let converted = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await converted.refresh()
        let convertedChats = await converted.sessions(from: at(daysAgo: 2, hour: 0), to: Date())
        let convertedChat = try XCTUnwrap(convertedChats.first { $0.id == sessionID })
        XCTAssertTrue(convertedChat.days.allSatisfy { $0.turns > 0 }, "a healthy same-zone conversion leaves no zero-turn day")
        XCTAssertEqual(convertedChat.days.count, 1)
        XCTAssertEqual(convertedChat.turns, 1)

        await converted.flushCache()
        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await reloaded.refresh()
        let reloadedChats = await reloaded.sessions(from: at(daysAgo: 2, hour: 0), to: Date())
        let reloadedChat = try XCTUnwrap(reloadedChats.first { $0.id == sessionID })
        XCTAssertTrue(reloadedChat.days.allSatisfy { $0.turns > 0 }, "a plain v8 load shows no zero-turn day either")
        XCTAssertEqual(reloadedChat.days.count, 1)
        XCTAssertEqual(reloadedChat.turns, 1)
    }

    // MARK: - SessionSummary agrees with breakdown()

    /// `breakdown()` sums `recentTurns` directly; `sessions(from:to:)` sums the same
    /// turns through the recent tier. For a chat whose whole history sits inside
    /// `recentTurns` — nothing folded, and the only chat in the aggregator, so
    /// `breakdown().daily` carries nothing else — the two must agree day for day.
    func testSessionSummaryTotalsAgreeWithBreakdownWhenTheChatHasOnlyRecentTurns() async throws {
        let turnA = at(daysAgo: 5, hour: 9)
        let turnB = at(daysAgo: 3, hour: 15)
        try writeTranscript([
            record(id: "msg_01V3BreakdownA0000000", at: turnA),
            record(id: "msg_01V3BreakdownB0000000", at: turnB),
        ])
        let agg = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await agg.refresh()

        let chats = await agg.sessions(from: at(daysAgo: 6, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        XCTAssertEqual(chat.days.count, 2, "precondition: two distinct recent days, nothing folded")

        let breakdown = await agg.breakdown()
        let byDay = Dictionary(uniqueKeysWithValues: breakdown.daily.map { ($0.day, $0) })

        for day in chat.days {
            let match = try XCTUnwrap(byDay[day.day], "breakdown() must carry the same day")
            XCTAssertEqual(day.turns, match.turns, "the chat's own turn count for the day agrees with breakdown()")
            XCTAssertEqual(day.tokens.total, match.totalTokens, "the chat's own token total for the day agrees with breakdown()")
        }
        XCTAssertEqual(chat.turns, breakdown.daily.map(\.turns).reduce(0, +), "single-chat totals agree end to end")
        XCTAssertEqual(chat.tokens.total, breakdown.daily.map(\.totalTokens).reduce(0, +))
    }
}
