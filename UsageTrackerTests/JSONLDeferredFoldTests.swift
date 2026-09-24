import XCTest
@testable import Omelette

/// Issue #10: a Claude Code reply more than 31 days old is counted — in its day and in
/// its chat — with the counters of its last log line, not its first; and the days and
/// chats a 2.6.1–2.6.4 cache already counted on first lines are repaired by
/// `cacheVersion` 7 (spec amendment of 2026-09-24: repair without losing data).
/// Spec `docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md` § Design #10 and the
/// P1 tests of § Packages.
///
/// The records are the shape Claude Code 2.1.280 writes on this Mac: a provisional
/// line (`stop_reason: null`, no `output_tokens_details`, a handful of output tokens),
/// then the final line under the same `message.id` about a second and a half later.
/// Copied from a sub-agent transcript, ids, paths and content scrubbed. Every day
/// boundary is UTC's, in the aggregator and in the fixtures alike; dollars come from
/// the static `ModelPricing` table.
final class JSONLDeferredFoldTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let sessionID = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let alphaSlug = "-Users-tester-Projects-alpha"

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLDeferredFoldTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixture records

    /// One `type: assistant` line. Without `thinking` and `stopReason` it is the
    /// provisional shape; with them, the final one.
    private func record(
        id: String,
        at date: Date,
        output: Int,
        thinking: Int? = nil,
        stopReason: String? = nil,
        session: String? = nil,
        agentID: String? = nil
    ) -> String {
        let details = thinking.map { ",\"output_tokens_details\":{\"thinking_tokens\":\($0)}" } ?? ""
        let stop = stopReason.map { "\"\($0)\"" } ?? "null"
        let agent = agentID.map { "\"agentId\":\"\($0)\",\"attributionAgent\":\"planner\"," } ?? ""
        return """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":\(agentID != nil),\(agent)\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"container":null,"stop_reason":\(stop),\
        "stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":16805,"cache_read_input_tokens":0,\
        "output_tokens":\(output)\(details),"service_tier":"standard",\
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

    /// What the parser makes of a `record`'s usage, priced the same way.
    private func counters(output: Int, thinking: Int = 0) -> TokenBreakdown {
        TokenBreakdown(input: 2, output: output, cacheWrite5m: 16_805, thinking: thinking)
            .priced(model: "claude-sonnet-4-5")
    }

    // MARK: - Fixture files

    /// `<root>/<project>/<sessionId>.jsonl`, where Claude Code keeps a chat's main transcript.
    private func mainURL(session: String? = nil) -> URL {
        root.appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent("\(session ?? sessionID).jsonl")
    }

    private func writeMain(_ lines: [String], session: String? = nil) throws {
        let url = mainURL(session: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Appends one line the way Claude Code does: size and mtime both move.
    private func append(_ line: String, session: String? = nil) throws {
        let handle = try FileHandle(forWritingTo: mainURL(session: session))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// `<root>/<project>/<sessionId>/subagents/agent-<id>.jsonl`.
    private func writeSubagent(_ lines: [String], agentID: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func makeAggregator(cache: URL? = nil) -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cache, saveInterval: 0, calendar: calendar)
    }

    // MARK: - The deferred fold

    func testAnOldReplyLoggedTwiceIsFoldedWithItsFinalCounts() async throws {
        let replyAt = at(daysAgo: 40, hour: 9)
        try writeMain([
            record(id: "msg_old", at: replyAt, output: 2),
            record(id: "msg_old", at: replyAt.addingTimeInterval(1.4), output: 2_000,
                   thinking: 1_500, stopReason: "tool_use"),
        ])

        let aggregator = makeAggregator()
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        let finalCounts = counters(output: 2_000, thinking: 1_500)

        XCTAssertEqual(day.turns, 1, "one reply, however many lines log it")
        XCTAssertEqual(day.tokens.output, 2_000, "the final count, not the provisional 2")
        XCTAssertEqual(day.tokens, finalCounts, "every counter and every dollar is the final line's")
        XCTAssertEqual(day.totalTokens, finalCounts.total)
        XCTAssertEqual(day.totalCost, try XCTUnwrap(finalCounts.cost).total, accuracy: 1e-12)
    }

    func testAnOldReplysChatSumsAgreeWithItsFoldedDay() async throws {
        let replyAt = at(daysAgo: 40, hour: 9)
        try writeMain([
            record(id: "msg_old", at: replyAt, output: 2),
            record(id: "msg_old", at: replyAt.addingTimeInterval(1.4), output: 2_000,
                   thinking: 1_500, stopReason: "tool_use"),
        ])

        let aggregator = makeAggregator()
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        let chats = await aggregator.sessions(from: dayStart(daysAgo: 45), to: now)
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })

        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(chat.tokens.output, 2_000, "the chat takes the final line, not the provisional 2")
        XCTAssertEqual(chat.tokens, day.tokens, "the chat and the day count the same reply the same way")
        XCTAssertEqual(chat.mainTokens, day.tokens, "a main-thread reply")
        XCTAssertEqual(chat.days.map(\.day), [dayStart(daysAgo: 40)])
        XCTAssertEqual(chat.days.map(\.tokens), [day.tokens])
        XCTAssertEqual(chat.models.map(\.id), ["claude-sonnet-4-5|xhigh"])
        XCTAssertEqual(chat.models.map(\.tokens), [day.tokens], "the model row takes the final line too")
        XCTAssertEqual(chat.firstAt, replyAt, "the reply's time is its first line's")
    }

    func testASubAgentsOldReplyTakesTheLastOfItsThreeLines() async throws {
        let agentID = "a0f3c9e1b7d24a615"
        let mainAt = at(daysAgo: 40, hour: 9)
        let agentAt = at(daysAgo: 40, hour: 10)
        try writeMain([
            record(id: "msg_main", at: mainAt, output: 2),
            record(id: "msg_main", at: mainAt.addingTimeInterval(1.4), output: 2_000,
                   thinking: 1_500, stopReason: "tool_use"),
        ])
        // The counts of a real sub-agent reply: a thinking block and a text block each
        // logged with the provisional 7, then the tool call with the final 208.
        try writeSubagent([
            record(id: "msg_agent", at: agentAt, output: 7, agentID: agentID),
            record(id: "msg_agent", at: agentAt.addingTimeInterval(0.57), output: 7, agentID: agentID),
            record(id: "msg_agent", at: agentAt.addingTimeInterval(1.424), output: 208,
                   thinking: 43, stopReason: "tool_use", agentID: agentID),
        ], agentID: agentID)

        let aggregator = makeAggregator()
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        let chats = await aggregator.sessions(from: dayStart(daysAgo: 45), to: now)
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        let agent = try XCTUnwrap(chat.agents.first { $0.id == agentID })
        let expectedCost = try XCTUnwrap(counters(output: 2_000, thinking: 1_500).cost).total
            + XCTUnwrap(counters(output: 208, thinking: 43).cost).total

        XCTAssertEqual(day.turns, 2)
        XCTAssertEqual(day.tokens.output, 2_208, "2,000 + 208: both replies at their final counts")
        XCTAssertEqual(day.tokens.thinking, 1_543)
        XCTAssertEqual(day.totalCost, expectedCost, accuracy: 1e-12)
        XCTAssertEqual(agent.turns, 1)
        XCTAssertEqual(agent.tokens.output, 208, "the agent row takes the final line, not the provisional 7")
        XCTAssertEqual(agent.tokens.thinking, 43)
        XCTAssertEqual(chat.mainTokens.output, 2_000)
        XCTAssertEqual(chat.tokens.output, day.tokens.output)
        XCTAssertEqual(chat.tokens.thinking, day.tokens.thinking)
        XCTAssertEqual(chat.models.first?.turns, 2)
        XCTAssertEqual(chat.models.first?.tokens.output, 2_208)
    }

    func testAnOldReplysProvisionalLineAfterItsFinalOneDoesNotShrinkIt() async throws {
        let replyAt = at(daysAgo: 40, hour: 9)
        try writeMain([
            record(id: "msg_old", at: replyAt, output: 2_000, thinking: 1_500, stopReason: "tool_use"),
            record(id: "msg_old", at: replyAt.addingTimeInterval(1.4), output: 2),
        ])

        let aggregator = makeAggregator()
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        let chats = await aggregator.sessions(from: dayStart(daysAgo: 45), to: now)
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })

        XCTAssertEqual(day.turns, 1)
        XCTAssertEqual(day.tokens.output, 2_000, "a replayed provisional line is not a later reading")
        XCTAssertEqual(chats.first { $0.id == sessionID }?.tokens.output, 2_000)
    }

    func testOldAndRecentRepliesInterleavedInOneTranscriptBothTakeTheirFinalLines() async throws {
        let oldAt = at(daysAgo: 40, hour: 9)
        let recentAt = now.addingTimeInterval(-600)
        try writeMain([
            record(id: "msg_old", at: oldAt, output: 2),
            record(id: "msg_recent", at: recentAt, output: 3),
            record(id: "msg_old", at: oldAt.addingTimeInterval(1.4), output: 2_000,
                   thinking: 1_500, stopReason: "tool_use"),
            record(id: "msg_recent", at: recentAt.addingTimeInterval(1.1), output: 900,
                   thinking: 100, stopReason: "end_turn"),
        ])

        let aggregator = makeAggregator()
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily
        let usage = await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
        let chats = await aggregator.sessions(from: dayStart(daysAgo: 45), to: now)
        let old = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })

        XCTAssertEqual(old.turns, 1)
        XCTAssertEqual(old.tokens.output, 2_000, "the old reply's final line")
        XCTAssertEqual(usage.turns, 1, "the old reply is not a recent one")
        XCTAssertEqual(usage.breakdown.output, 900, "the recent reply's final line, as before")
        XCTAssertEqual(chat.turns, 2)
        XCTAssertEqual(chat.tokens.output, 2_900)
    }

    /// The spec's known exception: a fork replaying an old id into another transcript
    /// stays unrevised, as it always was.
    func testAForkedReplayOfAnOldReplyInAnotherTranscriptStillChangesNothing() async throws {
        let forkID = "5f0c2d7e-8a41-4b6e-9c3d-2e7f1a9b8c60"
        let replyAt = at(daysAgo: 40, hour: 9)
        try writeMain([
            record(id: "msg_forked", at: replyAt, output: 2),
            record(id: "msg_forked", at: replyAt.addingTimeInterval(1.4), output: 2_000,
                   thinking: 1_500, stopReason: "tool_use"),
        ])
        let aggregator = makeAggregator()
        await aggregator.refresh()

        // A poll later a fork of the chat writes its own transcript: it replays the old
        // reply, with a bigger count than the one already folded, and adds one of its own.
        let ownAt = at(daysAgo: 40, hour: 11)
        try writeMain([
            record(id: "msg_forked", at: replyAt.addingTimeInterval(1.4), output: 5_000,
                   thinking: 1_500, stopReason: "tool_use", session: forkID),
            record(id: "msg_fork_own", at: ownAt, output: 2, session: forkID),
            record(id: "msg_fork_own", at: ownAt.addingTimeInterval(1.2), output: 300,
                   stopReason: "end_turn", session: forkID),
        ], session: forkID)
        await aggregator.refresh()

        let daily = await aggregator.breakdown().daily
        let chats = await aggregator.sessions(from: dayStart(daysAgo: 45), to: now)
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })

        XCTAssertEqual(day.turns, 2, "the replay is the same reply, not a second one")
        XCTAssertEqual(
            day.tokens.output, 2_300,
            "2,000 from the chat's own transcript + the fork's own 300; the replay's 5,000 is not adopted"
        )
        XCTAssertEqual(chats.first { $0.id == sessionID }?.tokens.output, 2_000)
        XCTAssertEqual(chats.first { $0.id == forkID }?.turns, 1, "the fork is charged for its own reply only")
        XCTAssertEqual(chats.first { $0.id == forkID }?.tokens.output, 300)
    }

    // MARK: - The bump to cache version 7

    /// Re-stamps the snapshot the aggregator itself wrote with another version number.
    /// The bytes stay a real build's; only the number differs. A 2.6.1–2.6.4 build wrote
    /// exactly this shape as version 6.
    private func stampCache(version: Int) throws {
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        let range = try XCTUnwrap(
            text.range(of: #""version":\d+"#, options: .regularExpression),
            "the snapshot carries its version number"
        )
        try text.replacingCharacters(in: range, with: "\"version\":\(version)")
            .write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    /// `{"type":"ai-title",…}`, the record that names a chat.
    private func titleLine(_ title: String, session: String) -> String {
        """
        {"type":"ai-title","aiTitle":"\(title)","sessionId":"\(session)"}
        """
    }

    func testAVersionSixDayNoTranscriptCoversAnyMoreSurvivesTheBump() async throws {
        let goneID = "0b7d6f3e-5a1c-4e0b-9d2f-6c8a1e4b7f90"
        let goneAt = at(daysAgo: 50, hour: 9)
        try writeMain([
            record(id: "msg_gone", at: goneAt, output: 2, session: goneID),
            record(id: "msg_gone", at: goneAt.addingTimeInterval(1.4), output: 500,
                   thinking: 120, stopReason: "end_turn", session: goneID),
        ], session: goneID)
        try writeMain([
            record(id: "msg_recent", at: now.addingTimeInterval(-600), output: 900,
                   thinking: 100, stopReason: "end_turn"),
        ])
        let first = makeAggregator(cache: cacheURL)
        await first.refresh()
        let firstDaily = await first.breakdown().daily
        let before = try XCTUnwrap(firstDaily.first { $0.day == dayStart(daysAgo: 50) })

        // Claude Code's cleanup takes the 50-day-old transcript; the cache on disk is the
        // one a 2.6.1–2.6.4 build wrote.
        try FileManager.default.removeItem(at: mainURL(session: goneID))
        try stampCache(version: 6)

        let migrated = makeAggregator(cache: cacheURL)
        await migrated.refresh()
        let parsed = await migrated.filesParsedInLastScan
        let daily = await migrated.breakdown().daily
        let recent = await migrated.usage(from: now.addingTimeInterval(-3600), to: now)
        let kept = try XCTUnwrap(
            daily.first { $0.day == dayStart(daysAgo: 50) },
            "the day only the old cache remembers is kept"
        )

        XCTAssertEqual(parsed, 1, "the version-6 marks are not trusted: the surviving transcript is read again")
        XCTAssertEqual(kept.turns, before.turns)
        XCTAssertEqual(kept.tokens.output, 500)
        XCTAssertEqual(kept.totalTokens, before.totalTokens)
        XCTAssertEqual(kept.totalCost, before.totalCost, accuracy: 1e-12)
        XCTAssertEqual(recent.turns, 1, "the re-read recent reply counts once; the old snapshot's copy is not kept")
        XCTAssertEqual(recent.breakdown.output, 900)

        // Once: the kept day went back to disk at the new version, and the next launch
        // reads nothing.
        let relaunched = makeAggregator(cache: cacheURL)
        await relaunched.refresh()
        let relaunchParsed = await relaunched.filesParsedInLastScan
        let relaunchDaily = await relaunched.breakdown().daily

        XCTAssertEqual(relaunchParsed, 0)
        XCTAssertEqual(relaunchDaily.first { $0.day == dayStart(daysAgo: 50) }?.turns, before.turns)
        XCTAssertEqual(relaunchDaily.first { $0.day == dayStart(daysAgo: 50) }?.tokens.output, 500)
    }

    func testADayASurvivingTranscriptCoversIsRebuiltNotDoubled() async throws {
        let otherID = "7c1e9a2b-3f4d-4e5a-8b6c-9d0e1f2a3b4c"
        let cutAt = at(daysAgo: 40, hour: 9)
        let wholeAt = at(daysAgo: 40, hour: 15)
        // The state a 2.6.4 build left behind: one chat's reply folded on its first,
        // provisional line …
        try writeMain([record(id: "msg_cut", at: cutAt, output: 2)])
        // … and another chat on the same day, whole.
        try writeMain([
            record(id: "msg_whole", at: wholeAt, output: 2, session: otherID),
            record(id: "msg_whole", at: wholeAt.addingTimeInterval(1.1), output: 1_000,
                   thinking: 200, stopReason: "end_turn", session: otherID),
        ], session: otherID)
        let first = makeAggregator(cache: cacheURL)
        await first.refresh()
        let staleDaily = await first.breakdown().daily
        let stale = try XCTUnwrap(staleDaily.first { $0.day == dayStart(daysAgo: 40) })
        XCTAssertEqual(stale.tokens.output, 1_002, "the cut reply went into the day at 2")

        // The transcript holds the final line too; the cache is a version-6 file.
        try append(record(id: "msg_cut", at: cutAt.addingTimeInterval(1.4), output: 2_000,
                          thinking: 1_500, stopReason: "tool_use"))
        try stampCache(version: 6)

        let migrated = makeAggregator(cache: cacheURL)
        await migrated.refresh()
        let daily = await migrated.breakdown().daily
        let chats = await migrated.sessions(from: dayStart(daysAgo: 45), to: now)
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 40) })
        let expectedCost = try XCTUnwrap(counters(output: 2_000, thinking: 1_500).cost).total
            + XCTUnwrap(counters(output: 1_000, thinking: 200).cost).total

        XCTAssertEqual(day.turns, 2, "two replies, each once: not the snapshot's two plus the re-read's two")
        XCTAssertEqual(day.tokens.output, 3_000, "2,000 + 1,000, rebuilt from the transcripts, not added onto 1,002")
        XCTAssertEqual(day.tokens.thinking, 1_700)
        XCTAssertEqual(day.totalCost, expectedCost, accuracy: 1e-9)
        XCTAssertEqual(chats.first { $0.id == sessionID }?.tokens.output, 2_000, "the chats are rebuilt with the day")
        XCTAssertEqual(chats.first { $0.id == otherID }?.tokens.output, 1_000)
        XCTAssertEqual(chats.map(\.turns).reduce(0, +), day.turns)
    }

    func testAVersionSixChatWhoseTranscriptIsGoneStaysListedAndASurvivingOneIsRebuilt() async throws {
        let goneID = "0b7d6f3e-5a1c-4e0b-9d2f-6c8a1e4b7f90"
        let goneAt = at(daysAgo: 60, hour: 9)
        try writeMain([
            titleLine("Kept by the cache", session: goneID),
            record(id: "msg_gone", at: goneAt, output: 2, session: goneID),
            record(id: "msg_gone", at: goneAt.addingTimeInterval(1.4), output: 500,
                   thinking: 120, stopReason: "end_turn", session: goneID),
        ], session: goneID)
        // The surviving chat as a 2.6.4 build left it: an old reply counted on its
        // provisional line, and a recent reply.
        let cutAt = at(daysAgo: 40, hour: 9)
        try writeMain([
            record(id: "msg_cut", at: cutAt, output: 2),
            record(id: "msg_recent", at: now.addingTimeInterval(-600), output: 900,
                   thinking: 100, stopReason: "end_turn"),
        ])
        let first = makeAggregator(cache: cacheURL)
        await first.refresh()
        let firstChats = await first.sessions(from: dayStart(daysAgo: 90), to: now)
        let goneBefore = try XCTUnwrap(firstChats.first { $0.id == goneID })
        XCTAssertEqual(
            firstChats.first { $0.id == sessionID }?.tokens.output, 902,
            "the cut reply went into its chat at 2"
        )

        // Claude Code's cleanup takes the 60-day-old transcript; the surviving one holds
        // the cut reply's final line too; the cache is a version-6 file.
        try FileManager.default.removeItem(at: mainURL(session: goneID))
        try append(record(id: "msg_cut", at: cutAt.addingTimeInterval(1.4), output: 2_000,
                          thinking: 1_500, stopReason: "tool_use"))
        try stampCache(version: 6)

        let migrated = makeAggregator(cache: cacheURL)
        await migrated.refresh()
        let chats = await migrated.sessions(from: dayStart(daysAgo: 90), to: now)
        let goneAfter = try XCTUnwrap(
            chats.first { $0.id == goneID },
            "a chat only the old cache remembers is still listed"
        )
        let survivor = try XCTUnwrap(chats.first { $0.id == sessionID })

        XCTAssertEqual(goneAfter, goneBefore, "name, totals, days and model rows exactly as the cache had them")
        XCTAssertEqual(goneAfter.title, "Kept by the cache")
        XCTAssertEqual(survivor.turns, 2, "rebuilt from its transcript: two replies, not the cache's two plus the re-read's two")
        XCTAssertEqual(survivor.tokens.output, 2_900, "2,000 + 900, not added onto the cache's 902")
        XCTAssertEqual(survivor.models.first?.turns, 2)
        XCTAssertEqual(survivor.models.first?.tokens.output, 2_900)
    }

    func testOnlyTheFirstScanAfterTheBumpRebuildsADay() async throws {
        let goneID = "0b7d6f3e-5a1c-4e0b-9d2f-6c8a1e4b7f90"
        try writeMain([
            record(id: "msg_gone", at: at(daysAgo: 50, hour: 9), output: 500,
                   thinking: 120, stopReason: "end_turn", session: goneID),
        ], session: goneID)
        let first = makeAggregator(cache: cacheURL)
        await first.refresh()
        try FileManager.default.removeItem(at: mainURL(session: goneID))
        try stampCache(version: 6)
        let migrated = makeAggregator(cache: cacheURL)
        await migrated.refresh()

        // A poll later a transcript with a reply on that same kept day turns up. The
        // rebuild was the first scan's job; from here on a fold adds to its day.
        let lateID = "3e5a7c9b-1d2f-4a6b-8c0d-e2f4a6b8c0d2"
        try writeMain([
            record(id: "msg_late", at: at(daysAgo: 50, hour: 20), output: 300,
                   stopReason: "end_turn", session: lateID),
        ], session: lateID)
        await migrated.refresh()
        let daily = await migrated.breakdown().daily
        let day = try XCTUnwrap(daily.first { $0.day == dayStart(daysAgo: 50) })

        XCTAssertEqual(day.turns, 2, "the kept reply and the late one")
        XCTAssertEqual(day.tokens.output, 800)
    }

    func testAVersionSixCacheForAnotherLogRootKeepsNothing() async throws {
        try writeMain([
            record(id: "msg_recent", at: now.addingTimeInterval(-600), output: 900, stopReason: "end_turn"),
        ])
        let object: [String: Any] = [
            "version": 6,
            "root": "/somewhere/else/projects",
            "savedAt": ISO8601DateFormatter().string(from: now),
            "fileMarks": [String: Any](),
            "recentTurns": [Any](),
            "oldDays": [[
                "day": ISO8601DateFormatter().string(from: dayStart(daysAgo: 50)),
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
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)

        let aggregator = makeAggregator(cache: cacheURL)
        await aggregator.refresh()
        let daily = await aggregator.breakdown().daily

        XCTAssertFalse(
            daily.contains { $0.day == dayStart(daysAgo: 50) },
            "another log root's days are not this one's to keep"
        )
    }
}
