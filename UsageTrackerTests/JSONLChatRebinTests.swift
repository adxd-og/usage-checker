import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Problem, § Design
/// and § Packages 2 (i), (ii), (iv), (vi), (vii): a Claude chat's days follow the time
/// zone — when the aggregator is told the zone moved, when the system posts it while
/// the app runs, and when a cache saved in one zone is loaded in another — land on the
/// days Activity shows for the same turns, and count every turn once. The record is
/// the shape Claude Code 2.1.280 writes (see `JSONLRekeyOnLoadTests`), ids and paths
/// scrubbed. The aggregator takes its 31-day window from the real clock, so turns are
/// placed relative to it, pinned to UTC: 30 days back is recent and 32 days back is
/// folded whatever the hour.
final class JSONLChatRebinTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let sessionID = "5b0e3c1a-7d42-4f96-a8e1-2c9d6b4f0a37"
    private let orphanID = "cccccccc-3333-4333-8333-333333333333"
    private let otherID = "dddddddd-4444-4444-8444-444444444444"
    private let alphaSlug = "-Users-tester-Projects-alpha"

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
            .appendingPathComponent("JSONLChatRebinTests-\(UUID().uuidString)", isDirectory: true)
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
    private func record(id: String, at date: Date, session: String? = nil) -> String {
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
        "sessionId":"\(session ?? sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// A chat's transcript, written whole. A longer file that starts with the same
    /// bytes is read from where the last scan stopped.
    private func writeTranscript(_ lines: [String], session: String? = nil) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcriptURL(session: session ?? sessionID), atomically: true, encoding: .utf8)
    }

    private func transcriptURL(session: String) -> URL {
        root.appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent("\(session).jsonl")
    }

    // MARK: - Loaded in another zone

    /// § Packages 2 (ii). A chat's recent days are rebuilt from the cached turns in the
    /// new zone, the way Activity recomputes its last 31 days: the midpoint rule alone
    /// kept the chat on the turn's UTC date while Activity showed the next one.
    func testALateEveningTurnSavedInUTCIsOnItsActivityDayAfterARelaunchAtUTCPlus3() async throws {
        let turnAt = at(daysAgo: 3, hour: 22, minute: 30)
        try writeTranscript([record(id: "msg_01RebinLoad00000000000", at: turnAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: plus3)
        await relaunched.refresh()

        let parsed = await relaunched.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the chat comes from the cache, not from reading the transcript again")
        let activityDays = await relaunched.breakdown().daily.map(\.day)
        XCTAssertEqual(activityDays, [plus3.startOfDay(for: turnAt)], "precondition: Activity bins the turn at UTC+3")
        let chats = await relaunched.sessions(from: turnAt, to: turnAt)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), activityDays, "the chat's day is the Activity day")
        XCTAssertEqual(chats.first?.turns, 1)
    }

    // MARK: - The v7 conversion

    /// A snapshot as the 2.7.0 build (cache version 7) left a chat whose transcript is
    /// gone: its days, both tiers in one, and none of its turns.
    private func orphanV7Snapshot(day: Date, turns: Int) -> Data {
        let tokens: [String: Any] = [
            "input": 7_777, "output": 0, "cacheRead": 0,
            "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
        ]
        let at = ISO8601DateFormatter().string(from: day.addingTimeInterval(9 * 3600))
        let object: [String: Any] = [
            "version": 7,
            "root": root.path,
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [Any](),
            "seenMessageIDs": [Any](),
            "sessions": [
                orphanID: [
                    "projectSlug": alphaSlug,
                    "firstAt": at,
                    "lastAt": at,
                    "days": [[
                        "day": ISO8601DateFormatter().string(from: day),
                        "turns": turns,
                        "tokens": tokens,
                        "mainTokens": tokens,
                    ]],
                    "agents": [String: Any](),
                    "byModel": [
                        "claude-sonnet-4-5|high": [
                            "model": "claude-sonnet-4-5",
                            "effort": "high",
                            "turns": turns,
                            "tokens": tokens,
                        ],
                    ],
                ],
            ],
            "titles": [orphanID: "A chat whose transcript is gone"],
            "firstPrompts": [String: Any](),
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// § Packages 2 (vi). The chat's days two days back hold turns no transcript and no
    /// `recentTurns` can give back. Converted with nothing to take out, they stay as
    /// folded sums, through the save at version 8 and the next launch.
    func testAV7ChatWithRecentDaysButNoTurnsOrTranscriptKeepsThemThroughTheCarryOverASaveAndAReload() async throws {
        let day = at(daysAgo: 2, hour: 0)
        try orphanV7Snapshot(day: day, turns: 5).write(to: cacheURL)

        let carried = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await carried.refresh()
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, 8, "the carried-over snapshot is saved back at version 8")

        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await reloaded.refresh()
        let chats = await reloaded.sessions(from: at(daysAgo: 3, hour: 0), to: now)
        let chat = try XCTUnwrap(chats.first { $0.id == orphanID })
        XCTAssertEqual(chat.days.map(\.day), [day])
        XCTAssertEqual(chat.turns, 5)
        XCTAssertEqual(chat.tokens.input, 7_777)
        XCTAssertEqual(chat.title, "A chat whose transcript is gone")
    }

    /// The v7 build saved a recent turn twice over — in its chat's days and in
    /// `recentTurns`. Read as version 8 it would count in both tiers; converted, the turn
    /// is taken back out of its saved day, nothing is read again, and it counts once.
    func testAChatSavedByTheV7BuildCountsEachTurnOnceAfterTheUpdate() async throws {
        let turnAt = at(daysAgo: 2, hour: 12)
        try writeTranscript([record(id: "msg_01RebinV7Once0000000000", at: turnAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        // The file as 2.7.0 wrote it: version 7, the chat's recent day in its `days`.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        let saved = try XCTUnwrap((json["recentTurns"] as? [[String: Any]])?.first)
        let tokens = try XCTUnwrap(saved["tokens"])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        sessions[sessionID]?["days"] = [[
            "day": ISO8601DateFormatter().string(from: utc.startOfDay(for: turnAt)),
            "turns": 1,
            "tokens": tokens,
            "mainTokens": tokens,
        ]]
        json["sessions"] = sessions
        json["version"] = 7
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)

        let updated = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await updated.refresh()

        let parsed = await updated.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "a v7 snapshot is converted: its marks are trusted, nothing is read again")
        let chats = await updated.sessions(from: turnAt, to: turnAt)
        XCTAssertEqual(chats.first?.turns, 1, "the turn counts once, not in both tiers")
    }

    /// The file the 2.7.0 build (cache version 7) wrote for the same state: every recent
    /// turn's day put back into its chat's saved `days`, beside the folded ones — except
    /// the recent turns of `leavingOut`, whose saved days then do not add up. The
    /// fixtures give each chat at most one recent turn per day, so a turn's day is an
    /// entry of its own.
    private func rewriteAsV7(leavingOut: String? = nil) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [String: [String: Any]])
        for turn in try XCTUnwrap(json["recentTurns"] as? [[String: Any]]) {
            let chat = try XCTUnwrap(turn["sessionID"] as? String)
            guard chat != leavingOut else { continue }
            let stamp = try XCTUnwrap(turn["timestamp"] as? String)
            let at = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))
            let tokens = try XCTUnwrap(turn["tokens"])
            var days = sessions[chat]?["days"] as? [[String: Any]] ?? []
            days.append([
                "day": ISO8601DateFormatter().string(from: utc.startOfDay(for: at)),
                "turns": 1,
                "tokens": tokens,
                "mainTokens": tokens,
            ])
            sessions[chat]?["days"] = days
        }
        json["sessions"] = sessions
        json["version"] = 7
        try JSONSerialization.data(withJSONObject: json).write(to: cacheURL)
    }

    /// § Packages 2 (vi-b). The file 2.7.0 left: day totals, marks, recent turns — one of
    /// them 30 days old, its transcript deleted since — and a chat with a folded day 40
    /// days back and that recent day, beside a second chat whose transcript is still
    /// there. Converted, nothing is read again, Activity still counts the 30-day turn,
    /// and both chats are exactly what they were, through a save and a v8 reload.
    func testAV7CacheIsConvertedWithoutReadingAnythingAgainAndKeepsATurnWhoseTranscriptIsGone() async throws {
        let foldedAt = at(daysAgo: 40, hour: 12)
        let recentAt = at(daysAgo: 30, hour: 12)
        try writeTranscript([
            record(id: "msg_01ConvFolded0000000000", at: foldedAt),
            record(id: "msg_01ConvRecent0000000000", at: recentAt),
        ])
        try writeTranscript(
            [record(id: "msg_01ConvOther00000000000", at: at(daysAgo: 2, hour: 12), session: otherID)],
            session: otherID
        )
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        let chatsBefore = await first.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        let dailyBefore = await first.breakdown().daily
        XCTAssertEqual(chatsBefore.count, 2, "precondition: both chats")
        try rewriteAsV7()
        try FileManager.default.removeItem(at: transcriptURL(session: sessionID))

        let converted = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await converted.refresh()

        let parsed = await converted.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the v7 marks are trusted: nothing is read again")
        let dailyAfter = await converted.breakdown().daily
        XCTAssertEqual(dailyAfter.map(\.day), dailyBefore.map(\.day))
        XCTAssertEqual(dailyAfter.map(\.turns), dailyBefore.map(\.turns))
        XCTAssertEqual(
            dailyAfter.first { $0.day == utc.startOfDay(for: recentAt) }?.turns, 1,
            "Activity still counts the 30-day turn whose transcript is gone"
        )
        let chatsAfter = await converted.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        XCTAssertEqual(chatsAfter, chatsBefore, "the folded day unchanged, the recent day the turn itself")
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, 8, "the converted snapshot is saved at version 8")

        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await reloaded.refresh()
        let chatsReloaded = await reloaded.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        XCTAssertEqual(chatsReloaded, chatsBefore, "and the same after a v8 reload")
    }

    /// § Packages 2 (vi-c). A v7 chat whose saved days do not cover one of its recent
    /// turns does not add up: the whole snapshot takes the carry-over — the transcript
    /// still on disk is read again — and the chat keeps the days it saved.
    func testAV7CacheWhoseChatDoesNotAddUpIsCarriedOverAndTheChatKeepsItsDays() async throws {
        let foldedAt = at(daysAgo: 40, hour: 12)
        try writeTranscript([
            record(id: "msg_01ConvBadFolded0000000", at: foldedAt),
            record(id: "msg_01ConvBadRecent0000000", at: at(daysAgo: 30, hour: 12)),
        ])
        try writeTranscript(
            [record(id: "msg_01ConvBadOther00000000", at: at(daysAgo: 2, hour: 12), session: otherID)],
            session: otherID
        )
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        try rewriteAsV7(leavingOut: sessionID)
        try FileManager.default.removeItem(at: transcriptURL(session: sessionID))

        let fallback = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await fallback.refresh()

        let parsed = await fallback.filesParsedInLastScan
        XCTAssertEqual(parsed, 1, "carried over: the transcript still on disk is read again")
        let chats = await fallback.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        XCTAssertEqual(chat.days.map(\.day), [utc.startOfDay(for: foldedAt)], "the day it saved, as a folded sum")
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chats.first { $0.id == otherID }?.turns, 1, "the chat read again is rebuilt, not doubled")
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, 8)
    }

    /// Review finding: a v7 cache saved in UTC and converted at UTC+3. Each recent turn
    /// leaves the day it was saved under before anything is re-keyed, so no turn counts
    /// twice or goes missing; the recent day is the turn's UTC+3 day, the folded day
    /// keeps its date. The transcript is gone, so nothing could rebuild the chat.
    func testAV7CacheConvertedInAnotherZoneCountsEveryTurnOnce() async throws {
        let foldedAt = at(daysAgo: 40, hour: 12)
        let recentAt = at(daysAgo: 3, hour: 22, minute: 30)
        try writeTranscript([
            record(id: "msg_01ConvZoneFolded000000", at: foldedAt),
            record(id: "msg_01ConvZoneRecent000000", at: recentAt),
        ])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        let before = try await totals(first)
        try rewriteAsV7()
        try FileManager.default.removeItem(at: transcriptURL(session: sessionID))

        let converted = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: plus3)
        await converted.refresh()

        let after = try await totals(converted)
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(after.tokens, before.tokens)
        XCTAssertEqual(after.mainTokens, before.mainTokens)
        let chats = await converted.sessions(from: at(daysAgo: 41, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        XCTAssertEqual(chat.days.map(\.day), [
            DayRekey.midpoint(utc.startOfDay(for: foldedAt), calendar: plus3),
            plus3.startOfDay(for: recentAt),
        ])
    }

    // MARK: - The fold

    /// The chat's turn and token counts over everything it holds. Dollars are left out:
    /// a sum taken in another order may differ in the last bit.
    private func totals(_ aggregator: JSONLAggregator) async throws -> (turns: Int, tokens: Int, mainTokens: Int) {
        let chats = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        return (chat.turns, chat.tokens.total, chat.mainTokens.total)
    }

    /// § Design "Rule": a turn leaving `recentTurns` moves from the recent tier to the
    /// folded one. The chat keeps its totals and its days, Activity keeps the turn once,
    /// and the turn is no longer among the recent turns. The fold is driven through
    /// `foldTurns(olderThan:)` with a cutoff one second past the 30-day turn.
    func testATurnThatFoldsMovesToTheFoldedTierAndTheChatKeepsItsTotals() async throws {
        let lateAt = at(daysAgo: 30, hour: 22, minute: 30)
        try writeTranscript([
            record(id: "msg_01RebinFoldLate00000000", at: lateAt),
            record(id: "msg_01RebinFoldRecent000000", at: at(daysAgo: 2, hour: 12)),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let lateWhileRecent = await aggregator.usage(from: lateAt.addingTimeInterval(-1), to: lateAt.addingTimeInterval(1))
        XCTAssertEqual(lateWhileRecent.turns, 1, "precondition: the 30-day turn is among the recent turns")
        let before = try await totals(aggregator)
        let daysBefore = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date()).first?.days.map(\.day)

        await aggregator.foldTurns(olderThan: lateAt.addingTimeInterval(1))

        let lateAfterFold = await aggregator.usage(from: lateAt.addingTimeInterval(-1), to: lateAt.addingTimeInterval(1))
        XCTAssertEqual(lateAfterFold.turns, 0, "the 30-day turn has left the recent turns")
        let after = try await totals(aggregator)
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(after.tokens, before.tokens)
        XCTAssertEqual(after.mainTokens, before.mainTokens)
        let daysAfter = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date()).first?.days.map(\.day)
        XCTAssertEqual(daysAfter, daysBefore, "the day keeps its key: same zone, one tier to the other")
        let lateDay = await aggregator.breakdown().daily.first { $0.day == utc.startOfDay(for: lateAt) }
        XCTAssertEqual(lateDay?.turns, 1, "Activity counts the folded turn once")
    }

    // MARK: - Told the zone moved

    /// § Packages 2 (i). Noon UTC is the same date at UTC+3 but not the same midnight:
    /// the single-day range History's 24h asks for missed the chat until a relaunch.
    func testAChatReadInUTCIsFoundOnItsDateAfterTheZoneMovesToUTCPlus3() async throws {
        let turnAt = at(daysAgo: 2, hour: 12)
        try writeTranscript([record(id: "msg_01RebinNoon00000000000", at: turnAt)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()

        await aggregator.timeZoneDidChange(calendar: plus3)

        let day = plus3.startOfDay(for: turnAt)
        let chats = await aggregator.sessions(from: day, to: day)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), [day])
        XCTAssertEqual(chats.first?.turns, 1)
    }

    /// 22:30 UTC is the next date at UTC+3. After the change the chat's day is the one
    /// Activity bins the same turn into.
    func testALateEveningTurnMovesToActivitysDateWhenTheZoneMovesEast() async throws {
        let turnAt = at(daysAgo: 3, hour: 22, minute: 30)
        try writeTranscript([record(id: "msg_01RebinLate00000000000", at: turnAt)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()

        await aggregator.timeZoneDidChange(calendar: plus3)

        let activityDays = await aggregator.breakdown().daily.map(\.day)
        XCTAssertEqual(activityDays, [plus3.startOfDay(for: turnAt)], "precondition: Activity bins the turn at UTC+3")
        let chats = await aggregator.sessions(from: turnAt, to: turnAt)
        XCTAssertEqual(chats.first?.days.map(\.day), activityDays)
    }

    /// The new calendar stays: a turn read after the change joins the day the re-bin
    /// filed instead of opening a second one under the old zone's midnight.
    func testATurnReadAfterTheChangeJoinsItsRebinnedDay() async throws {
        let first = at(daysAgo: 2, hour: 12)
        let second = at(daysAgo: 2, hour: 13)
        try writeTranscript([record(id: "msg_01RebinJoinA0000000000", at: first)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        await aggregator.timeZoneDidChange(calendar: plus3)

        try writeTranscript([
            record(id: "msg_01RebinJoinA0000000000", at: first),
            record(id: "msg_01RebinJoinB0000000000", at: second),
        ])
        await aggregator.refresh()

        let day = plus3.startOfDay(for: first)
        let chats = await aggregator.sessions(from: day, to: day)
        XCTAssertEqual(chats.first?.days.map(\.day), [day])
        XCTAssertEqual(chats.first?.days.map(\.turns), [2])
    }

    /// A change that moves nothing leaves every chat exactly as it was, folded day
    /// included — which is also what every launch in the zone the cache was saved in does.
    func testAChangeThatMovesNothingLeavesEveryChatAsItWas() async throws {
        try writeTranscript([
            record(id: "msg_01RebinKeepOld000000000", at: at(daysAgo: 40, hour: 12)),
            record(id: "msg_01RebinKeepMid000000000", at: at(daysAgo: 2, hour: 12)),
            record(id: "msg_01RebinKeepNew000000000", at: at(daysAgo: 1, hour: 22, minute: 30)),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let from = at(daysAgo: 41, hour: 0)
        let before = await aggregator.sessions(from: from, to: now)
        XCTAssertEqual(before.first?.days.count, 3, "precondition: a folded day and two recent ones")

        await aggregator.timeZoneDidChange(calendar: utc)

        let after = await aggregator.sessions(from: from, to: now)
        XCTAssertEqual(after, before)
    }

    /// § Packages 2 (iv). Turns on both sides of the fold — 01:00 UTC 32 days back is
    /// folded and 22:30 UTC 30 days back is recent whatever the hour, and both are within
    /// three hours of a midnight UTC±3 disagree on. The chat's turns and tokens stay what
    /// they were across UTC+3, UTC−3, and a fold of the 30-day turn after them (through
    /// `foldTurns(olderThan:)`, a cutoff one second past it): each turn is in one tier.
    func testAChatKeepsItsTotalsAcrossZoneChangesAndAFold() async throws {
        let lateAt = at(daysAgo: 30, hour: 22, minute: 30)
        try writeTranscript([
            record(id: "msg_01KeepFolded00000000000", at: at(daysAgo: 32, hour: 1)),
            record(id: "msg_01KeepLate000000000000", at: lateAt),
            record(id: "msg_01KeepRecent0000000000", at: at(daysAgo: 2, hour: 12)),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let lateWhileRecent = await aggregator.usage(
            from: lateAt.addingTimeInterval(-1), to: lateAt.addingTimeInterval(1)
        )
        XCTAssertEqual(lateWhileRecent.turns, 1, "precondition: the 30-day turn is among the recent turns")
        let before = try await totals(aggregator)
        XCTAssertEqual(before.turns, 3)

        await aggregator.timeZoneDidChange(calendar: plus3)
        let afterEast = try await totals(aggregator)
        await aggregator.timeZoneDidChange(calendar: minus3)
        let afterWest = try await totals(aggregator)

        await aggregator.foldTurns(olderThan: lateAt.addingTimeInterval(1))
        let lateAfterFold = await aggregator.usage(
            from: lateAt.addingTimeInterval(-1), to: lateAt.addingTimeInterval(1)
        )
        XCTAssertEqual(lateAfterFold.turns, 0, "the 30-day turn has left the recent turns")
        let afterFold = try await totals(aggregator)

        for (label, t) in [("UTC+3", afterEast), ("UTC−3", afterWest), ("the fold", afterFold)] {
            XCTAssertEqual(t.turns, before.turns, label)
            XCTAssertEqual(t.tokens, before.tokens, label)
            XCTAssertEqual(t.mainTokens, before.mainTokens, label)
        }
    }

    // MARK: - Posted by the system

    /// § Packages 2 (vii), § Design "Injection". The notice posted on the injected
    /// center reaches the actor once — `rebinCount` shows it under a fixed calendar,
    /// where no day moves — and the re-bin marks the chats for saving: a flush writes
    /// the cache file the test deleted.
    func testASystemZoneChangePostedWhileTheAppRunsReBinsTheChatsAndMarksThemForSaving() async throws {
        try writeTranscript([record(id: "msg_01RebinPost00000000000", at: at(daysAgo: 2, hour: 12))])
        let center = NotificationCenter()
        let aggregator = JSONLAggregator(
            rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc, center: center
        )
        await aggregator.refresh()
        let beforeNotice = await aggregator.rebinCount
        XCTAssertEqual(beforeNotice, 0, "precondition: no cache was loaded, nothing re-binned yet")
        try FileManager.default.removeItem(at: cacheURL)
        await aggregator.flushCache()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheURL.path), "precondition: nothing waits to be saved"
        )

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)

        // The hop is a task on the actor; it gets up to two seconds.
        var count = 0
        for _ in 0..<200 where count == 0 {
            count = await aggregator.rebinCount
            if count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(count, 1, "the notice reached the actor once")
        await aggregator.flushCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "the re-bin marked the chats for saving")
    }

    func testTheZoneObserverDoesNotKeepAReplacedAggregatorAlive() {
        let center = NotificationCenter()
        var aggregator: JSONLAggregator? = JSONLAggregator(
            rootURL: root, cacheURL: nil, calendar: utc, center: center
        )
        weak let released = aggregator
        aggregator = nil
        XCTAssertNil(released)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    }
}
