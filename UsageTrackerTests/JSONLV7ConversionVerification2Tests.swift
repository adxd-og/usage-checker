import XCTest
@testable import Omelette

/// Second-round independent verification of commit 8af9020 ("every v7 cache converts, a
/// turn past its day's 24 hours included"): spec
/// `docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md` § Design, "Cache"
/// paragraph as amended after its re-review — a v7 chat's recent turn is subtracted
/// from the saved day with the **latest key at or before its timestamp**, no upper
/// bound; a turn earlier than every key leaves the earliest day; a chat with no saved
/// days skips the turn; every counter floors at zero; a day whose turns reach zero is
/// removed; the conversion never fails and v7 has no fallback. Then `rebinChats()`. §
/// Packages 2 (vi-c), (vi-d).
///
/// Fixtures are built the way `JSONLV7ConversionVerificationTests` builds theirs: a
/// real `JSONLAggregator` writes a genuine v8 cache from real transcripts where a test
/// needs a real file on disk to prove nothing is re-read, and the cache file is then
/// hand-edited (`JSONSerialization`) to look like what a 2.7.0 (v7) build would have
/// saved — every turn still in `recentTurns` merged back into its chat's saved `days`
/// on top of whatever is already folded there — before bumping `version` to 7. Other
/// tests build the v7 (or v6, or v8) snapshot entirely by hand, since the scenario
/// (two zones' keys on one chat, a fall-back day, a day with no saved days, a saved day
/// smaller than the turn it must give back) cannot arise from a real ingest.
/// `CostCacheSnapshot` and `SessionAgg` are private to `JSONLAggregator`, so nothing
/// here reaches into the type; it goes through the cache file exactly as a real launch
/// would. Written independently: no assertion here is copied from
/// `JSONLV7ConversionVerificationTests`, `JSONLChatRebinTests` or
/// `JSONLChatTierRuleTests`.
final class JSONLV7ConversionVerification2Tests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus3: Calendar { Self.calendar(secondsFromGMT: 3 * 3600) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLV7ConversionVerification2Tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Time

    private static let alphaSlug = "-Users-v7verify2-Projects-alpha"

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Plain UTC, no fractional seconds: the only shape `JSONEncoder.dateEncodingStrategy
    /// = .iso8601` writes, and the only one its `.iso8601` decoder accepts back. Every
    /// hand-built or hand-read cache date in this file goes through this formatter.
    nonisolated(unsafe) private static let cacheISO = ISO8601DateFormatter()

    private func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            byAdding: .minute, value: hour * 60 + minute,
            to: utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        )!
    }

    // MARK: - Transcript fixtures (only where a real file is needed to prove no re-read)

    private func record(id: String, at date: Date, output: Int, session: String) -> String {
        """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message",\
        "role":"assistant","content":[{"type":"text","text":"…"}],"container":null,\
        "stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,\
        "output_tokens":\(output),"output_tokens_details":{"thinking_tokens":0},"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfVerify2Request0",\
        "type":"assistant","uuid":"8e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"high","perTurnEffort":"high",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown-2"}
        """
    }

    private func agentLine(id: String, at date: Date, agentID: String, output: Int, session: String) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CfVerify2AgentReq00","attributionAgent":"sub-agent",\
        "attributionSkill":"superpowers:writing-plans","attributionPlugin":"superpowers",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown-2",\
        "message":{"model":"claude-opus-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":0,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":\(output),"service_tier":"standard"}}}
        """
    }

    private func transcriptURL(session: String) -> URL {
        root.appendingPathComponent(Self.alphaSlug, isDirectory: true).appendingPathComponent("\(session).jsonl")
    }

    private func writeMain(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(Self.alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL(session: session), atomically: true, encoding: .utf8)
    }

    private func writeSubagent(_ lines: [String], agentID: String, session: String) throws {
        let dir = root.appendingPathComponent(Self.alphaSlug, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func aggregator(calendar: Calendar) -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: calendar)
    }

    // MARK: - Cache JSON helpers

    private func readCacheJSON() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
    }

    private func writeCacheJSON(_ json: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)
    }

    private func tokensDict(output: Int = 0, input: Int = 0) -> [String: Any] {
        ["input": input, "output": output, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0]
    }

    private func sumTokenDicts(_ dicts: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "thinking"] {
            result[key] = dicts.reduce(0) { $0 + (($1[key] as? Int) ?? 0) }
        }
        return result
    }

    private func dayDict(
        day: Date, turns: Int, tokens tks: [String: Any], mainTokens: [String: Any]? = nil
    ) -> [String: Any] {
        ["day": Self.cacheISO.string(from: day), "turns": turns, "tokens": tks, "mainTokens": mainTokens ?? tks]
    }

    private func turnDict(
        id: String, at date: Date, session: String, agentID: String? = nil, tokens tks: [String: Any]
    ) -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "timestamp": Self.cacheISO.string(from: date), "model": "claude-sonnet-4-5",
            "tokens": tks, "projectSlug": Self.alphaSlug, "sessionID": session,
        ]
        if let agentID { d["agentID"] = agentID }
        return d
    }

    private func turnDict(id: String, at date: Date, session: String, agentID: String? = nil, output: Int) -> [String: Any] {
        turnDict(id: id, at: date, session: session, agentID: agentID, tokens: tokensDict(output: output))
    }

    private func sessionAggDict(firstAt: Date, lastAt: Date, days: [[String: Any]]) -> [String: Any] {
        [
            "projectSlug": Self.alphaSlug, "firstAt": Self.cacheISO.string(from: firstAt),
            "lastAt": Self.cacheISO.string(from: lastAt), "days": days,
            "agents": [String: Any](), "byModel": [String: Any](),
        ]
    }

    private func cacheObject(
        version: Int, sessions: [String: Any], recentTurns: [[String: Any]] = [],
        fileMarks: [String: Any] = [:], titles: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "version": version, "root": root.path, "savedAt": Self.cacheISO.string(from: now),
            "fileMarks": fileMarks, "recentTurns": recentTurns, "oldDays": [Any](),
            "seenMessageIDs": [Int](), "sessions": sessions, "titles": titles,
            "firstPrompts": [String: Any](),
        ]
    }

    /// Rewrites the v8 cache just flushed at `cacheURL` into what a 2.7.0 (v7) build
    /// would have saved for the same state: every turn in `recentTurns` merged into its
    /// chat's saved `days` (same-day entries merged, as a real v7 `add` always does),
    /// beside whatever is already folded there. `version` becomes 7.
    private func mergeRecentTurnsIntoV7Days() throws {
        var json = try readCacheJSON()
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        let recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        for turn in recentTurns {
            guard let chat = turn["sessionID"] as? String else { continue }
            let stamp = try XCTUnwrap(turn["timestamp"] as? String)
            let turnAt = try XCTUnwrap(Self.cacheISO.date(from: stamp))
            let turnTokens = try XCTUnwrap(turn["tokens"] as? [String: Any])
            let isMain = (turn["agentID"] as? String) == nil
            let day = utc.startOfDay(for: turnAt)
            let dayKey = Self.cacheISO.string(from: day)
            var days = sessions[chat]?["days"] as? [[String: Any]] ?? []
            if let idx = days.firstIndex(where: { ($0["day"] as? String) == dayKey }) {
                var entry = days[idx]
                entry["turns"] = ((entry["turns"] as? Int) ?? 0) + 1
                entry["tokens"] = sumTokenDicts([(entry["tokens"] as? [String: Any]) ?? tokensDict(), turnTokens])
                if isMain {
                    entry["mainTokens"] = sumTokenDicts(
                        [(entry["mainTokens"] as? [String: Any]) ?? tokensDict(), turnTokens]
                    )
                }
                days[idx] = entry
            } else {
                days.append(dayDict(day: day, turns: 1, tokens: turnTokens, mainTokens: isMain ? turnTokens : tokensDict()))
            }
            sessions[chat]?["days"] = days
        }
        json["sessions"] = sessions
        json["version"] = 7
        try writeCacheJSON(json)
    }

    // MARK: - (1) A healthy same-zone conversion is exact, and nothing is re-read

    /// § Design "Cache": a v7 chat's mixed `days` become its folded tier minus its
    /// turns in `recentTurns`. With one folded turn and two recent turns (a main one
    /// and a sub-agent one, same civil day) merged into one v7 entry, the conversion
    /// must reproduce, exactly, the per-day and chat-level figures a genuine v8 run
    /// produced for the identical state — turns, tokens and mainTokens alike — and the
    /// surviving real transcript's marks must be trusted, not re-read.
    func testAHealthySameZoneV7CacheConvertsExactlyAndNothingIsReRead() async throws {
        let chat = "c7000000-0000-4000-8000-000000000001"
        let foldedAt = at(daysAgo: 45, hour: 8)
        let mainRecentAt = at(daysAgo: 3, hour: 9)
        let subRecentAt = at(daysAgo: 3, hour: 9, minute: 30)
        try writeMain([
            record(id: "msg_V2HealthyFolded00000000", at: foldedAt, output: 88, session: chat),
            record(id: "msg_V2HealthyMainRecent0000", at: mainRecentAt, output: 60, session: chat),
        ], session: chat)
        try writeSubagent(
            [agentLine(id: "msg_V2HealthySubRecent0000", at: subRecentAt, agentID: "agent-v2-healthy-1", output: 15, session: chat)],
            agentID: "agent-v2-healthy-1", session: chat
        )

        let first = aggregator(calendar: utc)
        await first.refresh()
        let beforeChats = await first.sessions(from: at(daysAgo: 46, hour: 0), to: now)
        let before = try XCTUnwrap(beforeChats.first { $0.id == chat })
        XCTAssertEqual(before.days.count, 2, "precondition: a folded day and a recent day")
        XCTAssertEqual(before.turns, 3)
        XCTAssertEqual(before.tokens.total, 163)
        XCTAssertEqual(before.mainTokens.total, 148, "precondition: the sub-agent turn stays out of mainTokens")
        await first.flushCache()

        try mergeRecentTurnsIntoV7Days()

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the surviving transcript's marks are trusted; the chat is converted, not re-read")

        let afterChats = await converted.sessions(from: at(daysAgo: 46, hour: 0), to: now)
        let after = try XCTUnwrap(afterChats.first { $0.id == chat })
        XCTAssertEqual(after.days.count, 2, "the recent day reappears once rebuilt from recentTurns")
        XCTAssertEqual(after.turns, before.turns, "an exact split reproduces the real v8 run's turn count")
        XCTAssertEqual(after.tokens.total, before.tokens.total, "an exact split reproduces the real v8 run's tokens")
        XCTAssertEqual(after.mainTokens.total, before.mainTokens.total, "mainTokens too: the sub-agent turn stays excluded")

        let foldedDay = try XCTUnwrap(after.days.first { $0.day == utc.startOfDay(for: foldedAt) })
        XCTAssertEqual(foldedDay.turns, 1)
        XCTAssertEqual(foldedDay.tokens.total, 88, "the folded day is untouched by the conversion")
        let recentDay = try XCTUnwrap(after.days.first { $0.day == utc.startOfDay(for: mainRecentAt) })
        XCTAssertEqual(recentDay.turns, 2, "main + sub-agent, exactly as the real run had it")
        XCTAssertEqual(recentDay.tokens.total, 75)

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - (2) Two zones' keys, 21 hours apart, on one chat

    /// § Packages 2 (vi-d): a v7 chat whose saved days are keyed in two zones (2.7.0
    /// re-keyed one day's entry after an in-process zone change without re-binning the
    /// turn) converts without a re-read, never goes negative, and the chat's total
    /// turns and tokens are conserved — reloaded, on top of that, under a third,
    /// explicit zone (UTC+3) neither key was saved in.
    func testTwoZoneKeysTwentyOneHoursApartConvertWithoutReReadAndConserveTotals() async throws {
        let dummy = "c7000000-0000-4000-8000-000000000098"
        try writeMain(
            [record(id: "msg_V2ZoneDummyMark00000000", at: at(daysAgo: 90, hour: 6), output: 1, session: dummy)],
            session: dummy
        )
        let first = aggregator(calendar: utc)
        await first.refresh()
        await first.flushCache()

        let chat = "c7000000-0000-4000-8000-000000000002"
        // The old zone's midnight (UTC) and, 21 h later, what a UTC+3 midnight looks
        // like expressed as a UTC instant — the shape a 2.7.0 in-process zone change
        // (Problem §1) would leave behind on one chat's saved `days`.
        let dayKeyOld = at(daysAgo: 3, hour: 0)
        let dayKeyNew = dayKeyOld.addingTimeInterval(21 * 3600)
        let recentTurnAt = dayKeyOld.addingTimeInterval(23 * 3600)

        var json = try readCacheJSON()
        var sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        sessions[chat] = sessionAggDict(firstAt: dayKeyOld, lastAt: dayKeyNew, days: [
            dayDict(day: dayKeyOld, turns: 1, tokens: tokensDict(output: 15)),
            dayDict(day: dayKeyNew, turns: 1, tokens: tokensDict(output: 25)),
        ])
        json["sessions"] = sessions
        var recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        recentTurns.append(turnDict(id: "msg_V2ZoneRecentTurn00000", at: recentTurnAt, session: chat, output: 25))
        json["recentTurns"] = recentTurns
        json["version"] = 7
        try writeCacheJSON(json)

        let converted = aggregator(calendar: plus3)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the dummy chat's surviving transcript is not re-read")

        let chats = await converted.sessions(from: dayKeyOld.addingTimeInterval(-5 * 86_400), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })
        XCTAssertEqual(after.turns, 2, "conserved: 2 turns went in, 2 come out")
        XCTAssertEqual(after.tokens.total, 40, "conserved: 15 + 25 tokens went in, 40 come out")
        XCTAssertEqual(after.mainTokens.total, 40)
        for day in after.days {
            XCTAssertGreaterThanOrEqual(day.turns, 0, "never negative")
            XCTAssertGreaterThanOrEqual(day.tokens.total, 0, "never negative")
        }

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - (3) A fall-back day: the turn is 24.5 h after its saved key

    /// § Packages 2 (vi-c): a v7 chat's recent turn 24.5 h after its saved day's key —
    /// past the naive 24-hour window a fall-back day's extra hour produces — still
    /// gives the turn back from that day (the only day it could possibly belong to)
    /// instead of failing the whole conversion, since the rule has no upper bound.
    func testARecentTurnInTheTwentyFifthHourOfAFallBackDayStillLeavesItsSavedDay() async throws {
        let chat = "c7000000-0000-4000-8000-000000000003"
        let dayKey = at(daysAgo: 10, hour: 0)
        let recentAt = dayKey.addingTimeInterval(24.5 * 3600)

        let sessions: [String: Any] = [
            chat: sessionAggDict(
                firstAt: dayKey, lastAt: recentAt,
                days: [dayDict(day: dayKey, turns: 3, tokens: tokensDict(output: 90))]
            ),
        ]
        let recentTurns = [turnDict(id: "msg_V2FallBackRecent00000", at: recentAt, session: chat, output: 20)]
        try writeCacheJSON(cacheObject(version: 7, sessions: sessions, recentTurns: recentTurns))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0)

        let chats = await converted.sessions(from: dayKey.addingTimeInterval(-86_400), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })
        let saved = try XCTUnwrap(after.days.first { $0.day == dayKey })
        XCTAssertEqual(saved.turns, 2, "the turn 24.5h past the key still left this day, not some other one")
        XCTAssertEqual(saved.tokens.total, 70, "90 - 20, the fall-back turn's own tokens given back")
        XCTAssertEqual(after.turns, 3, "2 folded remaining + 1 recent: conserved")
        XCTAssertEqual(after.tokens.total, 90)
    }

    // MARK: - (4) A chat with no saved days: the turn is skipped, not lost

    /// § Design "Cache": "a chat with no saved days has nothing to give back and the
    /// turn is skipped." The chat itself is still present in the v7 snapshot (an empty
    /// folded tier), so after the conversion and `rebinChats()`'s
    /// `rebuildRecentDays()`, its one recent turn must still show up — in the recent
    /// tier, since nowhere folded ever held it.
    func testARecentTurnWhoseChatHasNoSavedDaysIsSkippedAndStillShowsInTheRecentTier() async throws {
        let chat = "c7000000-0000-4000-8000-000000000004"
        let turnAt = at(daysAgo: 4, hour: 9)

        let sessions: [String: Any] = [
            chat: sessionAggDict(firstAt: turnAt, lastAt: turnAt, days: []),
        ]
        let recentTurns = [turnDict(id: "msg_V2OrphanRecent000000", at: turnAt, session: chat, output: 33)]
        try writeCacheJSON(cacheObject(version: 7, sessions: sessions, recentTurns: recentTurns))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let chats = await converted.sessions(from: at(daysAgo: 5, hour: 0), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat }, "the chat with no saved days must still exist")
        XCTAssertEqual(after.turns, 1, "nothing to give the turn back to, so it is skipped — not dropped")
        XCTAssertEqual(after.tokens.total, 33)
        XCTAssertEqual(after.days.count, 1)
        XCTAssertEqual(after.days.first?.day, utc.startOfDay(for: turnAt))

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - (5) A saved day smaller than the turn: floors at zero, then removed

    /// § Design "Cache": "every counter floors at zero... a day whose turns reach zero
    /// is removed." Two folded days, each smaller (in tokens) than the one recent turn
    /// each must give back: `dayA` has exactly one turn, so it is removed outright;
    /// `dayB` has three, so two survive with their token counters floored at zero
    /// rather than driven negative. The chat's overall totals after conversion must
    /// equal the recent turns given back plus whatever folded days survived.
    func testASavedDayHoldingFewerTokensThanTheTurnFloorsAtZeroAndIsRemovedOnceItsTurnsDo() async throws {
        let chat = "c7000000-0000-4000-8000-000000000005"
        // dayB is the earlier saved day, dayA the later one.
        let dayB = at(daysAgo: 7, hour: 0)
        let dayA = at(daysAgo: 6, hour: 0)
        let turnA = dayA.addingTimeInterval(2 * 3600)
        let turnB = dayB.addingTimeInterval(2 * 3600)

        let sessions: [String: Any] = [
            chat: sessionAggDict(firstAt: dayB, lastAt: dayA, days: [
                dayDict(day: dayB, turns: 3, tokens: tokensDict(input: 10)),
                dayDict(day: dayA, turns: 1, tokens: tokensDict(input: 5)),
            ]),
        ]
        let recentTurns = [
            turnDict(id: "msg_V2FloorTurnA00000000", at: turnA, session: chat, tokens: tokensDict(input: 999)),
            turnDict(id: "msg_V2FloorTurnB00000000", at: turnB, session: chat, tokens: tokensDict(input: 999)),
        ]
        try writeCacheJSON(cacheObject(version: 7, sessions: sessions, recentTurns: recentTurns))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let chats = await converted.sessions(from: dayB.addingTimeInterval(-86_400), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })

        let dayAEntry = try XCTUnwrap(after.days.first { $0.day == dayA })
        XCTAssertEqual(dayAEntry.turns, 1, "dayA's one folded turn was fully given back and the day removed")
        XCTAssertEqual(dayAEntry.tokens.input, 999, "what remains is only the recent turn's own share")

        let dayBEntry = try XCTUnwrap(after.days.first { $0.day == dayB })
        XCTAssertEqual(dayBEntry.turns, 3, "2 folded turns survive + 1 recent turn")
        XCTAssertEqual(
            dayBEntry.tokens.input, 999,
            "the folded share (10) minus the turn's (999) floors at zero rather than going negative"
        )

        XCTAssertEqual(after.turns, 4, "recent turns (2) + surviving folded turns (2 on dayB)")
        XCTAssertEqual(after.tokens.total, 1998, "recent tokens (999 + 999) + surviving folded tokens (0, floored)")
        XCTAssertEqual(after.mainTokens.total, 1998, "both turns are main-thread")
    }

    // MARK: - (6) A v6 snapshot still takes the carry-over (re-read) path

    /// § Facts / Design: `foldedDaysCarryOverVersions = [6]`; only 7 (`convertibleVersion`)
    /// is converted without a re-read. A v6 snapshot with a placeholder day for a chat
    /// whose transcript survives must have that placeholder wholly replaced by a fresh
    /// read of the transcript (`rebuiltChats`) — proof both that the carry-over path
    /// re-reads (`filesParsedInLastScan` counts the file) and that this commit's new
    /// "never fails" v7 logic did not leak into the v6 branch.
    func testAV6SnapshotWithASurvivingTranscriptTakesTheCarryOverPathAndReplacesThePlaceholder() async throws {
        let chat = "c7000000-0000-4000-8000-000000000006"
        let placeholderDay = at(daysAgo: 20, hour: 0)
        let realTurnAt = at(daysAgo: 2, hour: 9)
        try writeMain(
            [record(id: "msg_V2CarryOverReal00000", at: realTurnAt, output: 77, session: chat)], session: chat
        )

        let sessions: [String: Any] = [
            chat: sessionAggDict(
                firstAt: placeholderDay, lastAt: placeholderDay,
                days: [dayDict(day: placeholderDay, turns: 99, tokens: tokensDict(output: 99_999))]
            ),
        ]
        try writeCacheJSON(cacheObject(version: 6, sessions: sessions))

        let carried = aggregator(calendar: utc)
        await carried.refresh()

        let parsed = await carried.filesParsedInLastScan
        XCTAssertEqual(parsed, 1, "the carry-over path re-reads the surviving transcript; the v7/v8 paths would not")

        let chats = await carried.sessions(from: at(daysAgo: 25, hour: 0), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })
        XCTAssertEqual(after.turns, 1, "the placeholder's 99 turns are replaced, not added to")
        XCTAssertEqual(after.tokens.total, 77)
        XCTAssertEqual(after.days.map(\.day), [utc.startOfDay(for: realTurnAt)], "the placeholder day is gone")

        await carried.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - (7) A v8 snapshot is untouched by the v7 conversion rule

    /// § Design "Cache": conversion applies to `convertibleVersion` (7) only. A genuine
    /// v8 chat with a folded day and, on an unrelated later day, a recent turn already
    /// split into its own tier must not have that folded day mistaken for the recent
    /// turn's saved day and wrongly decremented — which is exactly what this commit's
    /// unconditional `subtractingRecentTurns` would do if it ran on the `cacheVersion`
    /// branch too.
    func testAV8SnapshotsFoldedDayIsUntouchedByTheV7SubtractionRule() async throws {
        let chat = "c7000000-0000-4000-8000-000000000007"
        let dayX = at(daysAgo: 10, hour: 0)
        let recentAt = at(daysAgo: 1, hour: 9)

        let sessions: [String: Any] = [
            chat: sessionAggDict(
                firstAt: dayX, lastAt: recentAt,
                days: [dayDict(day: dayX, turns: 5, tokens: tokensDict(output: 500))]
            ),
        ]
        let recentTurns = [turnDict(id: "msg_V2NoDoubleRecent0000", at: recentAt, session: chat, output: 42)]
        try writeCacheJSON(cacheObject(version: 8, sessions: sessions, recentTurns: recentTurns))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0)

        let chats = await converted.sessions(from: dayX.addingTimeInterval(-86_400), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })

        let dayXEntry = try XCTUnwrap(after.days.first { $0.day == dayX })
        XCTAssertEqual(dayXEntry.turns, 5, "unchanged: a v8 load never subtracts recentTurns from foldedDays")
        XCTAssertEqual(dayXEntry.tokens.total, 500, "would be 458 if the v7 subtraction wrongly ran here")

        let recentDay = try XCTUnwrap(after.days.first { $0.day == utc.startOfDay(for: recentAt) })
        XCTAssertEqual(recentDay.turns, 1)
        XCTAssertEqual(recentDay.tokens.total, 42)

        XCTAssertEqual(after.turns, 6)
        XCTAssertEqual(after.tokens.total, 542)

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }
}
