import XCTest
@testable import Omelette

/// Independent verification of the v7 → v8 Claude cost cache conversion: spec
/// `docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md` § Design, "Cache"
/// paragraph (revised 2026-09-25) and § Packages 2 (vi), (vi-b), (vi-c) — a v7
/// snapshot's `oldDays`, `fileMarks`, `recentTurns`, `seenMessageIDs`, titles and
/// prompts are restored exactly as a v8 load does, and each chat's mixed v7 `days`
/// become its folded tier minus the chat's turns in `recentTurns`, subtracted from the
/// saved day whose key `k` satisfies `k <= timestamp < k + 24h`; an inconsistent
/// snapshot falls back to the v6-style carry-over; then `rebinChats()`.
///
/// Fixtures are built the way `JSONLChatRebinTests` and
/// `JSONLCacheV7MigrationVerificationTests` build theirs: a real `JSONLAggregator`
/// writes a genuine v8 cache from real transcripts, and the cache file is then
/// hand-edited (`JSONSerialization`) to look like what a 2.7.0 (v7) build would have
/// saved for the same state — every turn still in `recentTurns` added back into its
/// chat's saved `days`, beside whatever is already folded there — before bumping
/// `version` to 7. `CostCacheSnapshot` is private to `JSONLAggregator`, so nothing here
/// reaches into the type; it goes through the file exactly as a real launch would.
/// Written independently: no assertion here is copied from `JSONLChatRebinTests` or
/// `JSONLChatTierRuleTests`.
final class JSONLV7ConversionVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let alphaSlug = "-Users-verifier-Projects-alpha"

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus3: Calendar { Self.calendar(secondsFromGMT: 3 * 3600) }
    private var minus3: Calendar { Self.calendar(secondsFromGMT: -3 * 3600) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLV7ConversionVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Fractional-second UTC, the shape a real Claude Code transcript line's own
    /// `timestamp` carries (`JSONLChatRebinTests.iso`).
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Plain UTC, no fractional seconds: what `JSONEncoder.dateEncodingStrategy =
    /// .iso8601` actually writes for every `Date` in a `CostCacheSnapshot`, and the only
    /// shape its `.iso8601` decoder accepts back. Every hand-built or hand-read cache
    /// date in this file goes through this formatter, never `iso` above.
    nonisolated(unsafe) private static let cacheISO = ISO8601DateFormatter()

    private func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            byAdding: .minute, value: hour * 60 + minute,
            to: utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        )!
    }

    // MARK: - Transcript fixtures

    /// One final `type: assistant` line of the main thread, output tokens parameterized
    /// so a test can compute an exact expected sum.
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
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfVerifyRequest00000",\
        "type":"assistant","uuid":"8e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"high","perTurnEffort":"high",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// A sub-agent record: `isSidechain`, `agentId`, `attributionAgent`, the parent's
    /// `sessionId`. Shape from `JSONLSessionsTests.agentTurn`.
    private func agentLine(id: String, at date: Date, agentID: String, output: Int, session: String) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CfVerifyAgentReq0000","attributionAgent":"sub-agent",\
        "attributionSkill":"superpowers:writing-plans","attributionPlugin":"superpowers",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"claude-opus-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":0,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":\(output),"service_tier":"standard"}}}
        """
    }

    private func transcriptURL(session: String) -> URL {
        root.appendingPathComponent(alphaSlug, isDirectory: true).appendingPathComponent("\(session).jsonl")
    }

    private func writeMain(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL(session: session), atomically: true, encoding: .utf8)
    }

    /// `<project>/<sessionId>/subagents/agent-<id>.jsonl`, exactly where Claude Code
    /// puts a sub-agent's transcript.
    private func writeSubagent(_ lines: [String], agentID: String, session: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
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

    private func tokens(_ output: Int) -> [String: Any] {
        ["input": 0, "output": output, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0]
    }

    private func sumTokenDicts(_ dicts: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "thinking"] {
            result[key] = dicts.reduce(0) { $0 + (($1[key] as? Int) ?? 0) }
        }
        return result
    }

    /// Rewrites the cache at `cacheURL` (already a genuine v8 snapshot from a real
    /// `refresh()`) to look like the file a 2.7.0 (v7) build would have saved for the
    /// same state: every turn still in `recentTurns` — except a chat named in
    /// `excluding` — added as its own entry to its chat's saved `days`, beside whatever
    /// is already folded there (a real v7 build merges same-day entries; a duplicate
    /// entry the day search still covers, since `subtractingRecentTurns` only asks for
    /// one entry with a spare turn). `version` becomes 7. A chat in `excluding` is left
    /// exactly as the v8 load saved it, so its saved days do not cover its recent turns.
    private func mergeRecentTurnsIntoSavedDays(excluding: Set<String> = []) throws {
        var json = try readCacheJSON()
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        let recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        for turn in recentTurns {
            guard let chat = turn["sessionID"] as? String, !excluding.contains(chat) else { continue }
            let stamp = try XCTUnwrap(turn["timestamp"] as? String)
            let turnAt = try XCTUnwrap(Self.cacheISO.date(from: stamp))
            let turnTokens = try XCTUnwrap(turn["tokens"] as? [String: Any])
            let isMain = (turn["agentID"] as? String) == nil
            var days = sessions[chat]?["days"] as? [[String: Any]] ?? []
            days.append([
                "day": Self.cacheISO.string(from: utc.startOfDay(for: turnAt)),
                "turns": 1,
                "tokens": turnTokens,
                "mainTokens": isMain ? turnTokens : tokens(0),
            ])
            sessions[chat]?["days"] = days
        }
        json["sessions"] = sessions
        json["version"] = 7
        try writeCacheJSON(json)
    }

    private func overallTotals(_ b: CLIBreakdown) -> (turns: Int, tokens: Int) {
        (b.daily.reduce(0) { $0 + $1.turns }, b.daily.reduce(0) { $0 + $1.totalTokens })
    }

    // MARK: - A 30-day-old recent turn with no transcript

    /// § Design "Cache": a chat's recent turn is taken back out of its saved day and
    /// lands in the recent tier, rebuilt from `recentTurns` — never re-read. A 30-day
    /// turn whose transcript is already gone by the time of the conversion must still
    /// show up in `breakdown()`, through the conversion itself and through a save and a
    /// v8 reload, since Claude Code deletes transcripts after 30 days by default.
    func testARecentTurnThirtyDaysOldWithNoTranscriptStillCountsInBreakdownAfterConversionAndAV8Reload() async throws {
        let chatA = "a0000000-0000-4000-8000-000000000001"
        let canary = "a0000000-0000-4000-8000-000000000002"
        let turnAt = at(daysAgo: 30, hour: 12)
        let canaryAt = at(daysAgo: 2, hour: 9)
        try writeMain([record(id: "msg_Verify30DayOnly0000000", at: turnAt, output: 40, session: chatA)], session: chatA)
        try writeMain([record(id: "msg_VerifyCanaryTurn000000", at: canaryAt, output: 20, session: canary)], session: canary)

        let first = aggregator(calendar: utc)
        await first.refresh()
        await first.flushCache()

        try mergeRecentTurnsIntoSavedDays()
        try FileManager.default.removeItem(at: transcriptURL(session: chatA))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(
            parsed, 0,
            "converted, not carried over: the canary's surviving transcript would be re-read if the whole load fell back"
        )

        let dailyAfter = await converted.breakdown().daily
        let day30 = try XCTUnwrap(dailyAfter.first { $0.day == utc.startOfDay(for: turnAt) })
        XCTAssertEqual(day30.turns, 1, "the 30-day turn, transcript gone, still counts in Activity after the conversion")
        XCTAssertEqual(day30.totalTokens, 40)

        let chats = await converted.sessions(from: at(daysAgo: 31, hour: 0), to: now)
        let chatSummary = try XCTUnwrap(chats.first { $0.id == chatA })
        XCTAssertEqual(chatSummary.turns, 1)
        XCTAssertEqual(chatSummary.tokens.total, 40)

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8, "the converted snapshot is saved back at version 8")

        let reloaded = aggregator(calendar: utc)
        await reloaded.refresh()
        let reloadedParsed = await reloaded.filesParsedInLastScan
        XCTAssertEqual(reloadedParsed, 0, "a v8 reload never re-reads the gone transcript either")
        let reloadedDaily = await reloaded.breakdown().daily
        let reloadedDay30 = try XCTUnwrap(reloadedDaily.first { $0.day == utc.startOfDay(for: turnAt) })
        XCTAssertEqual(reloadedDay30.turns, 1, "still counted after the v8 round trip")
    }

    // MARK: - A folded day mixing a surviving and a deleted transcript's share

    /// § Design "Cache": the folded tier is untouched where no recent turn covers it. A
    /// single calendar day 40 days back holds one turn from a transcript still on disk
    /// and one from a transcript deleted since; the conversion touches neither share,
    /// and nothing is re-read to confirm it (`filesParsedInLastScan == 0`, the surviving
    /// file's marks left exactly as the v7 cache trusted them).
    func testAFoldedDayMixingASurvivingAndADeletedTranscriptsShareKeepsTheFullAmountWithNothingReRead() async throws {
        let chatP = "f0000000-0000-4000-8000-000000000001"
        let chatQ = "f0000000-0000-4000-8000-000000000002"
        let pAt = at(daysAgo: 40, hour: 8)
        let qAt = at(daysAgo: 40, hour: 20)
        let foldedDay = utc.startOfDay(for: pAt)
        try writeMain([record(id: "msg_VerifyMixP0000000000", at: pAt, output: 12, session: chatP)], session: chatP)
        try writeMain([record(id: "msg_VerifyMixQ0000000000", at: qAt, output: 34, session: chatQ)], session: chatQ)

        let first = aggregator(calendar: utc)
        await first.refresh()
        let dailyBefore = await first.breakdown().daily
        let day40Before = try XCTUnwrap(dailyBefore.first { $0.day == foldedDay })
        XCTAssertEqual(day40Before.turns, 2, "precondition: both chats' turns land on the same folded day")
        XCTAssertEqual(day40Before.totalTokens, 46)
        await first.flushCache()

        // Neither turn is in `recentTurns` (both are already 40 days old when read), so
        // the file 2.7.0 wrote for this state needs no `days` edits — only the version.
        var json = try readCacheJSON()
        json["version"] = 7
        try writeCacheJSON(json)
        try FileManager.default.removeItem(at: transcriptURL(session: chatQ))

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "chatP's surviving transcript is not re-read either: the day is converted, not carried over")

        let dailyAfter = await converted.breakdown().daily
        let day40After = try XCTUnwrap(dailyAfter.first { $0.day == foldedDay })
        XCTAssertEqual(day40After.turns, 2, "the deleted transcript's share is not lost from the app-wide day")
        XCTAssertEqual(day40After.totalTokens, 46)

        let chats = await converted.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let pChat = try XCTUnwrap(chats.first { $0.id == chatP })
        let qChat = try XCTUnwrap(chats.first { $0.id == chatQ })
        XCTAssertEqual(pChat.tokens.total, 12, "the surviving transcript's own share")
        XCTAssertEqual(qChat.tokens.total, 34, "the deleted transcript's share, kept whole")

        await converted.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - A parent turn and a sub-agent turn on the same recent day

    /// § Design "Cache" + "Claude" (`mainTokens` split): two recent turns on the same
    /// day — a main-thread one and a sub-agent one — merge into a single saved v7 day.
    /// The conversion must subtract both (turns 2 → 0, the day removed) and rebuild the
    /// recent day correctly split: `mainTokens` from the main turn alone, `tokens` from
    /// both. A 40-day folded day, which no recent turn covers, stays exactly as saved.
    func testAParentAndASubAgentTurnOnTheSameRecentDayGiveTheCorrectMainTokensAndLeaveTheFoldedDayUntouched() async throws {
        let chat = "b0000000-0000-4000-8000-000000000001"
        let foldedAt = at(daysAgo: 40, hour: 8)
        let mainRecentAt = at(daysAgo: 2, hour: 9)
        let subRecentAt = at(daysAgo: 2, hour: 10)
        try writeMain([
            record(id: "msg_VerifyMixFolded0000000", at: foldedAt, output: 100, session: chat),
            record(id: "msg_VerifyMixMainRecent000", at: mainRecentAt, output: 50, session: chat),
        ], session: chat)
        try writeSubagent(
            [agentLine(id: "msg_VerifyMixSubRecent000", at: subRecentAt, agentID: "agent-mix-1", output: 30, session: chat)],
            agentID: "agent-mix-1", session: chat
        )

        let first = aggregator(calendar: utc)
        await first.refresh()
        let beforeChats = await first.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let before = try XCTUnwrap(beforeChats.first { $0.id == chat })
        XCTAssertEqual(before.days.count, 2, "precondition: a folded day and a recent day")
        XCTAssertEqual(before.turns, 3)
        XCTAssertEqual(before.tokens.total, 180)
        XCTAssertEqual(before.mainTokens.total, 150, "precondition: the sub-agent turn is not in mainTokens")
        await first.flushCache()

        var json = try readCacheJSON()
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        let recentTurns = try XCTUnwrap(json["recentTurns"] as? [[String: Any]])
        let mainTurnTokens = try XCTUnwrap(
            recentTurns.first { ($0["sessionID"] as? String) == chat && ($0["agentID"] as? String) == nil }?["tokens"]
                as? [String: Any]
        )
        let subTurnTokens = try XCTUnwrap(
            recentTurns.first { ($0["sessionID"] as? String) == chat && ($0["agentID"] as? String) != nil }?["tokens"]
                as? [String: Any]
        )
        var days = try XCTUnwrap(sessions[chat]?["days"] as? [[String: Any]])
        // One merged v7 entry for the recent day: this is what a real v7 build's `add`
        // (which always merges same-day entries) would have saved.
        days.append([
            "day": Self.cacheISO.string(from: utc.startOfDay(for: mainRecentAt)),
            "turns": 2,
            "tokens": sumTokenDicts([mainTurnTokens, subTurnTokens]),
            "mainTokens": mainTurnTokens,
        ])
        sessions[chat]?["days"] = days
        json["sessions"] = sessions
        json["version"] = 7
        try writeCacheJSON(json)

        let converted = aggregator(calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "converted, marks trusted")

        let chats = await converted.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let after = try XCTUnwrap(chats.first { $0.id == chat })
        XCTAssertEqual(after.days.count, 2, "the recent day reappears once rebuilt from `recentTurns`")
        XCTAssertEqual(after.turns, 3)
        XCTAssertEqual(after.tokens.total, 180, "conserved: main + sub-agent")
        XCTAssertEqual(after.mainTokens.total, 150, "the sub-agent's tokens stay out of mainTokens after the merge is undone")
        let foldedDay = try XCTUnwrap(after.days.first { $0.day == utc.startOfDay(for: foldedAt) })
        XCTAssertEqual(foldedDay.tokens.total, 100, "the 40-day folded day, which no recent turn covers, is untouched")
    }

    // MARK: - An inconsistent chat falls back for the whole load

    /// § Design "Cache": "If any subtraction finds no such day ... the whole load falls
    /// back to the v6-style carry-over" — not just the chat that does not add up. A
    /// second, individually-convertible chat's saved folded day is deliberately
    /// corrupted; if the fallback were scoped to the broken chat alone, the corrupted
    /// chat would convert via subtraction and its saved marks would stay trusted
    /// (no re-read). The spec's "whole load" wording means every chat's transcript is
    /// read again instead.
    func testAV7SnapshotWhoseChatDoesNotAddUpFallsBackForTheWholeLoadNotJustThatChat() async throws {
        let good = "c0000000-0000-4000-8000-000000000001"
        let bad = "c0000000-0000-4000-8000-000000000002"
        let goodFoldedAt = at(daysAgo: 40, hour: 8)
        let goodRecentAt = at(daysAgo: 2, hour: 9)
        let badFoldedAt = at(daysAgo: 40, hour: 10)
        let badRecentAt = at(daysAgo: 2, hour: 11)
        try writeMain([
            record(id: "msg_VerifyGoodFolded000000", at: goodFoldedAt, output: 15, session: good),
            record(id: "msg_VerifyGoodRecent000000", at: goodRecentAt, output: 25, session: good),
        ], session: good)
        try writeMain([
            record(id: "msg_VerifyBadFolded0000000", at: badFoldedAt, output: 35, session: bad),
            record(id: "msg_VerifyBadRecent0000000", at: badRecentAt, output: 45, session: bad),
        ], session: bad)

        let first = aggregator(calendar: utc)
        await first.refresh()
        await first.flushCache()

        // `bad`'s recent turn is left uncovered: its saved days do not add up.
        try mergeRecentTurnsIntoSavedDays(excluding: [bad])

        // `good` converts cleanly on its own — corrupt its folded day so a scoped
        // fallback (converting `good`, carrying over only `bad`) would leave the
        // corruption in place, while the spec's whole-load fallback rebuilds it from
        // the transcript.
        var json = try readCacheJSON()
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        var goodDays = try XCTUnwrap(sessions[good]?["days"] as? [[String: Any]])
        let foldedIndex = try XCTUnwrap(
            goodDays.firstIndex { ($0["day"] as? String) == Self.cacheISO.string(from: utc.startOfDay(for: goodFoldedAt)) }
        )
        goodDays[foldedIndex]["turns"] = 5
        goodDays[foldedIndex]["tokens"] = tokens(999)
        goodDays[foldedIndex]["mainTokens"] = tokens(999)
        sessions[good]?["days"] = goodDays
        json["sessions"] = sessions
        try writeCacheJSON(json)

        let fallback = aggregator(calendar: utc)
        await fallback.refresh()

        let parsed = await fallback.filesParsedInLastScan
        XCTAssertEqual(
            parsed, 2, "the whole snapshot falls back: both chats' transcripts are read again, not just the broken one"
        )

        let chats = await fallback.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let goodChat = try XCTUnwrap(chats.first { $0.id == good })
        let goodFoldedDay = try XCTUnwrap(goodChat.days.first { $0.day == utc.startOfDay(for: goodFoldedAt) })
        XCTAssertEqual(
            goodFoldedDay.turns, 1,
            "rebuilt from the transcript, not left at the corrupted value a chat-scoped conversion would have kept"
        )
        XCTAssertEqual(goodFoldedDay.tokens.total, 15)
        XCTAssertEqual(goodChat.turns, 2, "good's recent turn is rebuilt too, not lost")

        let badChat = try XCTUnwrap(chats.first { $0.id == bad })
        XCTAssertEqual(badChat.turns, 2, "the chat that did not add up is rebuilt too, not left half-converted")

        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8)
    }

    // MARK: - Conversion under a different calendar

    /// § Packages 2 (iv)'s conservation rule, extended to the v7 conversion path (§
    /// Design "Cache"): a v7 cache saved in UTC and converted at UTC+3 and at UTC−3
    /// conserves every chat's turn and token totals, and the whole aggregator's, across
    /// two chats each holding a folded turn and a recent turn near a zone boundary.
    /// Transcripts are deleted before either conversion, so nothing but the conversion
    /// math could be producing the conserved totals.
    func testConversionUnderADifferentCalendarConservesPerChatAndOverallTotalsAtUTCPlus3AndUTCMinus3() async throws {
        let chatA = "d0000000-0000-4000-8000-000000000001"
        let chatB = "d0000000-0000-4000-8000-000000000002"
        let aFoldedAt = at(daysAgo: 40, hour: 12)
        let aRecentAt = at(daysAgo: 3, hour: 22, minute: 30)
        let bFoldedAt = at(daysAgo: 41, hour: 6)
        let bRecentAt = at(daysAgo: 4, hour: 23, minute: 15)
        try writeMain([
            record(id: "msg_VerifyZoneAFolded0000", at: aFoldedAt, output: 70, session: chatA),
            record(id: "msg_VerifyZoneARecent0000", at: aRecentAt, output: 33, session: chatA),
        ], session: chatA)
        try writeMain([
            record(id: "msg_VerifyZoneBFolded0000", at: bFoldedAt, output: 55, session: chatB),
            record(id: "msg_VerifyZoneBRecent0000", at: bRecentAt, output: 44, session: chatB),
        ], session: chatB)

        let first = aggregator(calendar: utc)
        await first.refresh()
        let beforeChats = await first.sessions(from: at(daysAgo: 42, hour: 0), to: now)
        let beforeA = try XCTUnwrap(beforeChats.first { $0.id == chatA })
        let beforeB = try XCTUnwrap(beforeChats.first { $0.id == chatB })
        let beforeOverall = overallTotals(await first.breakdown())
        await first.flushCache()

        try mergeRecentTurnsIntoSavedDays()
        let v7Bytes = try Data(contentsOf: cacheURL)
        try FileManager.default.removeItem(at: transcriptURL(session: chatA))
        try FileManager.default.removeItem(at: transcriptURL(session: chatB))

        let plus3Agg = aggregator(calendar: plus3)
        await plus3Agg.refresh()
        try await assertConserved(
            plus3Agg, chatA: chatA, chatB: chatB, beforeA: beforeA, beforeB: beforeB, beforeOverall: beforeOverall,
            label: "UTC+3"
        )

        try v7Bytes.write(to: cacheURL)
        let minus3Agg = aggregator(calendar: minus3)
        await minus3Agg.refresh()
        try await assertConserved(
            minus3Agg, chatA: chatA, chatB: chatB, beforeA: beforeA, beforeB: beforeB, beforeOverall: beforeOverall,
            label: "UTC-3"
        )
    }

    private func assertConserved(
        _ agg: JSONLAggregator, chatA: String, chatB: String,
        beforeA: SessionSummary, beforeB: SessionSummary, beforeOverall: (turns: Int, tokens: Int), label: String
    ) async throws {
        let chats = await agg.sessions(from: at(daysAgo: 42, hour: 0), to: now)
        let afterA = try XCTUnwrap(chats.first { $0.id == chatA })
        let afterB = try XCTUnwrap(chats.first { $0.id == chatB })
        XCTAssertEqual(afterA.turns, beforeA.turns, label)
        XCTAssertEqual(afterA.tokens.total, beforeA.tokens.total, label)
        XCTAssertEqual(afterA.mainTokens.total, beforeA.mainTokens.total, label)
        XCTAssertEqual(afterB.turns, beforeB.turns, label)
        XCTAssertEqual(afterB.tokens.total, beforeB.tokens.total, label)
        XCTAssertEqual(afterB.mainTokens.total, beforeB.mainTokens.total, label)
        let overall = overallTotals(await agg.breakdown())
        XCTAssertEqual(overall.turns, beforeOverall.turns, label)
        XCTAssertEqual(overall.tokens, beforeOverall.tokens, label)
    }

    // MARK: - Zero chats

    /// § Design "Cache": nothing in the design excludes an empty snapshot. A v7 cache
    /// with no chats at all must still load without crashing and be saved back at
    /// version 8.
    func testAV7SnapshotWithZeroChatsStillLoadsAndIsSavedBackAsV8() async throws {
        let object: [String: Any] = [
            "version": 7,
            "root": root.path,
            "savedAt": Self.cacheISO.string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [Any](),
            "seenMessageIDs": [Any](),
            "sessions": [String: Any](),
            "titles": [String: Any](),
            "firstPrompts": [String: Any](),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)

        let agg = aggregator(calendar: utc)
        await agg.refresh()

        let parsed = await agg.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "nothing on disk to scan, and nothing to convert")
        let chats = await agg.sessions(from: at(daysAgo: 10, hour: 0), to: now)
        XCTAssertTrue(chats.isEmpty)
        let daily = await agg.breakdown().daily
        XCTAssertTrue(daily.isEmpty)

        await agg.flushCache()
        let onDisk = try readCacheJSON()
        XCTAssertEqual(onDisk["version"] as? Int, 8, "an empty v7 snapshot is still saved back at version 8")
        XCTAssertEqual((onDisk["sessions"] as? [String: Any])?.count, 0)
    }

    // MARK: - A v8 snapshot is not converted twice

    /// § Design "Cache": conversion applies to `convertibleVersion` (7) only; a genuine
    /// v8 snapshot takes the `cacheVersion` branch and skips `subtractingRecentTurns`
    /// entirely. A chat with a folded day and a recent day on different dates — so its
    /// folded tier alone does not cover the recent turn — would fail a wrongly-repeated
    /// subtraction; a save, a reload and a second reload must leave both tiers, and the
    /// file's marks, exactly as they were.
    func testAV8SnapshotIsNotConvertedTwice() async throws {
        let chat = "e0000000-0000-4000-8000-000000000001"
        let foldedAt = at(daysAgo: 40, hour: 8)
        let recentAt = at(daysAgo: 2, hour: 9)
        try writeMain([
            record(id: "msg_VerifyNoDoubleFolded00", at: foldedAt, output: 60, session: chat),
            record(id: "msg_VerifyNoDoubleRecent00", at: recentAt, output: 20, session: chat),
        ], session: chat)

        let first = aggregator(calendar: utc)
        await first.refresh()
        let firstChats = await first.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let before = try XCTUnwrap(firstChats.first { $0.id == chat })
        XCTAssertEqual(before.days.count, 2, "precondition: a folded day and a recent day, exactly what a genuine v8 cache carries")
        await first.flushCache()
        let onDiskFirst = try readCacheJSON()
        XCTAssertEqual(onDiskFirst["version"] as? Int, 8, "precondition: a genuine v8 cache")

        let reloaded = aggregator(calendar: utc)
        await reloaded.refresh()

        let parsed = await reloaded.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "a v8 load never runs the v7 conversion: its marks are trusted as they are")
        let reloadedChats = await reloaded.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let after = try XCTUnwrap(reloadedChats.first { $0.id == chat })
        XCTAssertEqual(after.days, before.days, "both tiers reconstruct to exactly what they were, untouched by a second conversion pass")
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(after.tokens.total, before.tokens.total)
        XCTAssertEqual(after.mainTokens.total, before.mainTokens.total)

        // A second relaunch on the file this one just saved: still stable.
        await reloaded.flushCache()
        let againReloaded = aggregator(calendar: utc)
        await againReloaded.refresh()
        let parsedAgain = await againReloaded.filesParsedInLastScan
        XCTAssertEqual(parsedAgain, 0)
        let againReloadedChats = await againReloaded.sessions(from: at(daysAgo: 41, hour: 0), to: now)
        let afterAgain = try XCTUnwrap(againReloadedChats.first { $0.id == chat })
        XCTAssertEqual(afterAgain.days, before.days)
    }
}
