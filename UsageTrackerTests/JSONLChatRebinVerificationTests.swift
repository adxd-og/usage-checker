import XCTest
@testable import Omelette

/// Verification of Claude's day-tier rules against
/// docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design and § Packages
/// 2, complementing (not duplicating) the executor's own `JSONLChatRebinTests` and
/// `JSONLChatTierRuleTests`. Covers: a half-hour zone (UTC+5:30, the spec's own
/// example, never exercised end to end by the executor's suite); a relaunch that moves
/// a turn's civil day *backward*; that `timeZoneDidChange` never schedules a second,
/// asynchronous re-bin through `DayBinCache.reset()`; `sessions(from:to:)` summing a
/// civil day that has an entry in both tiers at once; `byModel`/`agents` surviving a
/// real actor-level re-bin with a sub-agent turn in the mix; the v6 carry-over (the
/// executor tested v7 only); `revise` landing on the recent tier; and `drop(before:)`
/// pruning both tiers. Fixed epochs, explicit calendars, `en_US_POSIX`, a temp root per
/// test — nothing here touches the process's time zone or the real Application Support.
final class JSONLChatRebinVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let sessionID = "7f1a9c3e-4b5d-4a12-9e6f-3d8b2c1a0f45"
    private let agentID = "b1e4a7c92f5d3861"
    private let orphanID = "dddddddd-4444-4444-8444-444444444444"
    private let alphaSlug = "-Users-tester-Projects-alpha"

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus5h30: Calendar { Self.calendar(secondsFromGMT: 5 * 3600 + 1800) }
    private var minus3: Calendar { Self.calendar(secondsFromGMT: -3 * 3600) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLChatRebinVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    /// One final `type: assistant` line of the main thread. `outputTokens` is what
    /// `laterReading` compares to decide whether a second line for the same `id` is a
    /// revision.
    private func record(id: String, at date: Date, outputTokens: Int = 208) -> String {
        """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message",\
        "role":"assistant","content":[{"type":"text","text":"…"}],"container":null,\
        "stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":16805,"cache_read_input_tokens":0,\
        "output_tokens":\(outputTokens),"output_tokens_details":{"thinking_tokens":0},"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":16805},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfVerifyRequest000000",\
        "type":"assistant","uuid":"9f3a5b7d-2c4e-4f6a-b8d0-1e3f5a7b9c2d",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh","perTurnEffort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// A sub-agent record: `isSidechain`, `agentId`, `attributionAgent`, and the
    /// parent's `sessionId`, as `JSONLSessionsTests` builds one.
    private func agentTurn(id: String, at date: Date, outputTokens: Int = 40) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CfVerifyAgent0000000","attributionAgent":"planner",\
        "attributionSkill":"superpowers:writing-plans","attributionPlugin":"superpowers",\
        "type":"assistant","uuid":"1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"claude-opus-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":900,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":\(outputTokens),"service_tier":"standard"}}}
        """
    }

    private func writeTranscript(_ lines: [String], session: String? = nil) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(session ?? sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func writeSubagentTranscript(_ lines: [String]) throws {
        let dir = root
            .appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func totals(_ aggregator: JSONLAggregator) async throws -> (turns: Int, tokens: Int, mainTokens: Int) {
        let chats = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        return (chat.turns, chat.tokens.total, chat.mainTokens.total)
    }

    // MARK: - A half-hour zone

    /// § Packages 2 (iv), spelled out for UTC+5:30 (§ Packages "conservation... and a
    /// half-hour zone"): a chat's turn and token totals are unchanged by a move to a
    /// non-integer-hour zone, and by the fold that follows it.
    func testAChatKeepsItsTotalsAcrossAHalfHourZoneChangeAndTheFoldThatFollows() async throws {
        let lateAt = at(daysAgo: 30, hour: 22, minute: 30)
        try writeTranscript([
            record(id: "msg_01VerifyFolded000000000", at: at(daysAgo: 32, hour: 1)),
            record(id: "msg_01VerifyLate0000000000", at: lateAt),
            record(id: "msg_01VerifyRecent00000000", at: at(daysAgo: 2, hour: 12)),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let before = try await totals(aggregator)
        XCTAssertEqual(before.turns, 3)

        await aggregator.timeZoneDidChange(calendar: plus5h30)
        let afterZone = try await totals(aggregator)
        XCTAssertEqual(afterZone.turns, before.turns, "UTC+5:30")
        XCTAssertEqual(afterZone.tokens, before.tokens, "UTC+5:30")
        XCTAssertEqual(afterZone.mainTokens, before.mainTokens, "UTC+5:30")

        await aggregator.foldTurns(olderThan: lateAt.addingTimeInterval(1))
        let afterFold = try await totals(aggregator)
        XCTAssertEqual(afterFold.turns, before.turns, "the fold that follows the half-hour move")
        XCTAssertEqual(afterFold.tokens, before.tokens, "the fold that follows the half-hour move")
        XCTAssertEqual(afterFold.mainTokens, before.mainTokens, "the fold that follows the half-hour move")
    }

    // MARK: - A relaunch that moves the day backward

    /// The executor's own relaunch tests all move the day forward (a late-evening UTC
    /// turn into a more easterly zone). This one moves it backward: 00:30 UTC is still
    /// "yesterday" at UTC−3, and the chat's day after the relaunch must be the day
    /// Activity gives the same turn, not the day it was saved under.
    func testAnEarlyMorningTurnIsOnThePreviousActivityDayAfterARelaunchAtUTCMinus3() async throws {
        let turnAt = at(daysAgo: 3, hour: 0, minute: 30)
        try writeTranscript([record(id: "msg_01VerifyBackward00000000", at: turnAt)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: minus3)
        await relaunched.refresh()

        let parsed = await relaunched.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the chat comes from the cache, not from reading the transcript again")
        let expectedDay = minus3.startOfDay(for: turnAt)
        XCTAssertLessThan(
            expectedDay, utc.startOfDay(for: turnAt),
            "precondition: UTC−3 moves 00:30 UTC to the previous civil day"
        )
        let activityDays = await relaunched.breakdown().daily.map(\.day)
        XCTAssertEqual(activityDays, [expectedDay], "precondition: Activity bins the turn on the previous UTC−3 day")
        let chats = await relaunched.sessions(from: expectedDay, to: expectedDay)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), activityDays, "the chat's day is the Activity day, one day back")
    }

    // MARK: - No second, asynchronous re-bin

    /// § Design "Injection": `DayBinCache.reset()` "never calls the handler". A direct
    /// `timeZoneDidChange(calendar:)` call resets the bin cache through that same path,
    /// so it must re-bin exactly once — never a second time a moment later, which would
    /// be the symptom of `reset()` wrongly notifying its own caller back.
    func testATimeZoneDidChangeNeverSchedulesASecondAsynchronousRebin() async throws {
        try writeTranscript([record(id: "msg_01VerifyNoDouble0000000", at: at(daysAgo: 2, hour: 12))])
        let aggregator = JSONLAggregator(
            rootURL: root, cacheURL: nil, calendar: utc, center: NotificationCenter()
        )
        await aggregator.refresh()
        let baseline = await aggregator.rebinCount

        await aggregator.timeZoneDidChange(calendar: plus5h30)

        let immediately = await aggregator.rebinCount
        XCTAssertEqual(immediately, baseline + 1, "exactly one re-bin for the direct call")
        try await Task.sleep(for: .milliseconds(300))
        let afterAWait = await aggregator.rebinCount
        XCTAssertEqual(afterAWait, baseline + 1, "no delayed second re-bin arrived from the reset")
    }

    // MARK: - A day split across both tiers

    /// § Design "Rule": "the same civil day may have an entry in both tiers; a query
    /// sums them." Two turns of one UTC day, the earlier one folded out from under the
    /// later one by a cutoff that sits between them — `sessions(from:to:)` must read the
    /// day as both tiers' turns and tokens added together, not just one tier's.
    func testSessionsSumsBothTiersWhenOneCivilDayHasAnEntryInEach() async throws {
        let earlier = at(daysAgo: 2, hour: 6)
        let later = at(daysAgo: 2, hour: 18)
        try writeTranscript([
            record(id: "msg_01VerifySplitA00000000", at: earlier, outputTokens: 100),
            record(id: "msg_01VerifySplitB00000000", at: later, outputTokens: 300),
        ])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let day = utc.startOfDay(for: earlier)
        let before = await aggregator.sessions(from: day, to: day)
        XCTAssertEqual(before.first?.turns, 2, "precondition: both turns are recent, on one day")

        await aggregator.foldTurns(olderThan: earlier.addingTimeInterval(3_600))

        let stillRecent = await aggregator.usage(from: later.addingTimeInterval(-1), to: later.addingTimeInterval(1))
        XCTAssertEqual(stillRecent.turns, 1, "precondition: the later turn is still in recentTurns")
        let chats = await aggregator.sessions(from: day, to: day)
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        XCTAssertEqual(chat.days.map(\.day), [day], "one civil day, entries in both tiers merged into one row")
        XCTAssertEqual(chat.turns, 2, "the folded turn and the still-recent turn both count")
        XCTAssertEqual(chat.tokens.output, 400)
    }

    // MARK: - What a real re-bin leaves alone

    /// § Packages 2 (v), exercised through the actor rather than the value type: a chat
    /// with a sub-agent turn keeps its `models` and `agents` rows byte-for-byte equal
    /// after `timeZoneDidChange` moves its days.
    func testARealRebinLeavesModelsAndAgentsExactlyEqual() async throws {
        let mainAt = at(daysAgo: 2, hour: 9)
        let agentAt = mainAt.addingTimeInterval(300)
        try writeTranscript([record(id: "msg_01VerifyRebinMain0000000", at: mainAt)])
        try writeSubagentTranscript([agentTurn(id: "msg_01VerifyRebinAgent000000", at: agentAt)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let day = utc.startOfDay(for: mainAt)
        let beforeSessions = await aggregator.sessions(from: day, to: day)
        let before = try XCTUnwrap(beforeSessions.first { $0.id == sessionID })
        XCTAssertEqual(before.agents.count, 1, "precondition: one sub-agent")

        await aggregator.timeZoneDidChange(calendar: plus5h30)

        let newDay = plus5h30.startOfDay(for: mainAt)
        let afterSessions = await aggregator.sessions(from: newDay, to: newDay)
        let after = try XCTUnwrap(afterSessions.first { $0.id == sessionID })
        XCTAssertEqual(after.models, before.models)
        XCTAssertEqual(after.agents, before.agents)
    }

    // MARK: - The v6 carry-over

    /// A snapshot as the pre-2.7.0 build (cache version 6) left a chat whose transcript
    /// is gone: `foldedDaysCarryOverVersions` names 6 and 7 both, so a v6 chat's days
    /// must survive the v8 carry-over, a save, and a reload exactly as a v7 chat's do.
    private func orphanV6Snapshot(day: Date, turns: Int) -> Data {
        let tokens: [String: Any] = [
            "input": 5_555, "output": 0, "cacheRead": 0,
            "cacheWrite5m": 0, "cacheWrite1h": 0, "thinking": 0,
        ]
        let at = ISO8601DateFormatter().string(from: day.addingTimeInterval(9 * 3600))
        let object: [String: Any] = [
            "version": 6,
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
            "titles": [orphanID: "A v6 chat whose transcript is gone"],
            "firstPrompts": [String: Any](),
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testAV6ChatWithNoTranscriptKeepsItsDaysThroughTheV8CarryOverASaveAndAReload() async throws {
        let day = at(daysAgo: 2, hour: 0)
        try orphanV6Snapshot(day: day, turns: 4).write(to: cacheURL)

        let carried = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await carried.refresh()
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        XCTAssertEqual(onDisk?["version"] as? Int, 8, "the v6 snapshot is saved back at version 8")

        let reloaded = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await reloaded.refresh()
        let chats = await reloaded.sessions(from: at(daysAgo: 3, hour: 0), to: now)
        let chat = try XCTUnwrap(chats.first { $0.id == orphanID })
        XCTAssertEqual(chat.days.map(\.day), [day])
        XCTAssertEqual(chat.turns, 4)
        XCTAssertEqual(chat.tokens.input, 5_555)
        XCTAssertEqual(chat.title, "A v6 chat whose transcript is gone")
    }

    // MARK: - Revise lands on the recent tier

    /// § Design "Rule": "`revise` applies to the recent tier, where the turn still
    /// lives." A provisional record (small `output_tokens`) followed by the final one
    /// for the same message id must not double the turn count, and the day's tokens
    /// must be the final reading's, not the sum of both.
    func testAReviseIsCountedOnceOnTheRecentTier() async throws {
        let turnAt = at(daysAgo: 1, hour: 12)
        let id = "msg_01VerifyRevise000000000"
        try writeTranscript([record(id: id, at: turnAt, outputTokens: 2)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let provisional = try await totals(aggregator)
        XCTAssertEqual(provisional.turns, 1)

        // The file grows by one line, the way Claude Code appends the final record
        // after the provisional one: the scan reads only the new bytes and takes the
        // `replaceIfLater` path, never re-reading the first line as a second turn.
        try writeTranscript([
            record(id: id, at: turnAt, outputTokens: 2),
            record(id: id, at: turnAt, outputTokens: 208),
        ])
        await aggregator.refresh()

        let final = try await totals(aggregator)
        XCTAssertEqual(final.turns, 1, "one message id is one turn, however many lines revised it")
        let day = utc.startOfDay(for: turnAt)
        let daySessions = await aggregator.sessions(from: day, to: day)
        let chat = try XCTUnwrap(daySessions.first { $0.id == sessionID })
        XCTAssertEqual(chat.tokens.output, 208, "the day carries the final reading, not the provisional plus the final")
    }

    // MARK: - drop(before:) prunes both tiers

    /// § Design "Rule": "`drop(before:)` prunes both tiers." A day older than the
    /// cutoff must leave whichever tier it is in; a day at or after it must stay.
    func testDropBeforePrunesBothTiers() {
        let oldFolded = at(daysAgo: 200, hour: 12)
        let oldRecent = at(daysAgo: 100, hour: 12)
        let keptFolded = at(daysAgo: 50, hour: 12)
        let keptRecent = at(daysAgo: 2, hour: 12)
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: oldFolded)
        func turn(_ id: String, at date: Date) -> CLITurn {
            CLITurn(
                id: id, timestamp: date, model: "claude-sonnet-4-5",
                tokens: TokenBreakdown(input: 100, output: 10).priced(model: "claude-sonnet-4-5"),
                projectSlug: alphaSlug, sessionID: sessionID
            )
        }
        agg.add(turn("a", at: oldFolded), on: utc.startOfDay(for: oldFolded), recent: false)
        agg.add(turn("b", at: oldRecent), on: utc.startOfDay(for: oldRecent), recent: true)
        agg.add(turn("c", at: keptFolded), on: utc.startOfDay(for: keptFolded), recent: false)
        agg.add(turn("d", at: keptRecent), on: utc.startOfDay(for: keptRecent), recent: true)
        XCTAssertEqual(agg.foldedDays.count, 2, "precondition")
        XCTAssertEqual(agg.recentDays.count, 2, "precondition")

        let cutoff = at(daysAgo: 90, hour: 0)
        agg.drop(before: cutoff)

        XCTAssertEqual(agg.foldedDays.map(\.day), [utc.startOfDay(for: keptFolded)], "the old folded day is gone")
        XCTAssertEqual(agg.recentDays.map(\.day), [utc.startOfDay(for: keptRecent)], "the old recent day is gone")
    }
}
