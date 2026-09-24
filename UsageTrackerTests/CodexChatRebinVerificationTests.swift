import XCTest
@testable import Omelette

/// Verification of Codex's day-tier rules against
/// docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design ("Codex") and
/// § Packages 3, complementing (not duplicating) the executor's own
/// `CodexChatRebinTests`. Covers: a half-hour zone (UTC+5:30); a relaunch — a fresh
/// aggregator instance over the same rollouts, since "Codex rebuilds from rollouts"
/// (§ Facts 2) rather than caching a chat — landing on the same day Activity gives the
/// same response; that `timeZoneDidChange` never schedules a second, asynchronous
/// re-bin; `sessions(from:to:)` summing a civil day with an entry in both tiers;
/// `models`/`agents` surviving a real re-bin with a sub-agent thread in the mix; and a
/// stronger, per-day check that repricing rebuilds only the recent tier's dollars.
/// Fixed epochs, explicit calendars, `en_US_POSIX` — nothing here touches the process's
/// time zone or the network.
final class CodexChatRebinVerificationTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now = Date()
    private let cwd = "/tmp/Codex Verify/alpha app"
    private let agentCwd = "/tmp/Codex Verify/alpha app/agent"
    private let model = "gpt-5.6-terra"
    private let sessionID = "02b1d4e3-6f80-7b29-ac5d-3e7f9a1b2c46"
    private let agentThreadID = "agent-verify-thread"
    /// "gpt-5.6-terra" resolves to this row through `dynamicLookup`'s suffix strip.
    private let terra = ModelPrice(
        inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
        cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
    )

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus5h30: Calendar { Self.calendar(secondsFromGMT: 5 * 3600 + 1800) }
    private var minus3: Calendar { Self.calendar(secondsFromGMT: -3 * 3600) }

    /// The live price table is process-global: every test starts and ends with it
    /// empty, as `CodexRepricingTests` does.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexChatRebinVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    /// `hour:minute` UTC on the UTC day `daysAgo` days before today.
    private func at(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
        utc.date(
            byAdding: .minute, value: hour * 60 + minute,
            to: utc.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        )!
    }

    /// One rollout of the main thread with a `token_usage_record` at each instant:
    /// 1_000 in (400 cached) and 100 out, 1_100 tokens a response.
    private func writeRollout(responsesAt instants: [Date], named name: String) throws {
        let opened = instants.min()!
        var lines = [
            CodexRollout.sessionMeta(sessionID: sessionID, cwd: cwd, at: opened.addingTimeInterval(-60)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: opened.addingTimeInterval(-30)),
        ]
        for (i, instant) in instants.enumerated() {
            lines.append(CodexRollout.record(
                at: instant, threadID: sessionID, responseID: "resp_verify_\(name)_\(i)",
                input: 1_000, cached: 400, output: 100, reasoning: 30
            ))
        }
        try tree.writeRollout(lines, named: "rollout-2026-09-06T02-09-23-\(name).jsonl")
    }

    /// A sub-agent rollout: its own file, its own thread id, `session_id` the parent's.
    private func writeSubagentRollout(at instant: Date) throws {
        let lines = [
            CodexRollout.subagentMeta(
                sessionID: sessionID, threadID: agentThreadID, parentThreadID: sessionID,
                nickname: "Explore", agentPath: nil, cwd: agentCwd, at: instant.addingTimeInterval(-30)
            ),
            CodexRollout.turnContext(model: model, cwd: agentCwd, at: instant.addingTimeInterval(-15)),
            CodexRollout.record(
                at: instant, threadID: agentThreadID, sessionID: sessionID,
                responseID: "resp_verify_agent", input: 500, cached: 0, output: 40, reasoning: 0
            ),
        ]
        try tree.writeRollout(lines, named: "rollout-2026-09-06T02-10-00-agent.jsonl")
    }

    private func totals(_ aggregator: CodexUsageAggregator) async throws -> (turns: Int, tokens: Int, mainTokens: Int) {
        let chats = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        return (chat.turns, chat.tokens.total, chat.mainTokens.total)
    }

    // MARK: - A half-hour zone

    /// § Packages 3 (ii) spelled out for UTC+5:30: a chat's response and token totals
    /// are unchanged by a move to a non-integer-hour zone, and by the fold after it.
    func testAChatKeepsItsTotalsAcrossAHalfHourZoneChangeAndTheFoldThatFollows() async throws {
        let lateAt = at(daysAgo: 30, hour: 22, minute: 30)
        try writeRollout(
            responsesAt: [at(daysAgo: 32, hour: 1), lateAt, at(daysAgo: 2, hour: 12)], named: "half-hour"
        )
        let aggregator = tree.aggregator(calendar: utc)
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

    /// § Facts 2: "Codex rebuilds from rollouts" rather than caching a chat, so its
    /// "relaunch in another zone" is a fresh aggregator instance over the same files. A
    /// response at 00:30 UTC is still "yesterday" at UTC−3, and the chat's day the new
    /// instance reports must be the day its own Activity gives the same response.
    func testAnEarlyMorningResponseIsOnThePreviousActivityDayAfterARelaunchAtUTCMinus3() async throws {
        let responseAt = at(daysAgo: 3, hour: 0, minute: 30)
        try writeRollout(responsesAt: [responseAt], named: "backward")
        let expectedDay = minus3.startOfDay(for: responseAt)
        XCTAssertLessThan(
            expectedDay, utc.startOfDay(for: responseAt),
            "precondition: UTC−3 moves 00:30 UTC to the previous civil day"
        )

        let relaunched = tree.aggregator(calendar: minus3)
        await relaunched.refresh()

        let activityDays = await relaunched.breakdown(now: now).daily.map(\.day)
        XCTAssertEqual(activityDays, [expectedDay], "precondition: Activity bins the response on the previous day")
        let chats = await relaunched.sessions(from: expectedDay, to: expectedDay)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), activityDays, "the chat's day is the Activity day, one day back")
    }

    // MARK: - No second, asynchronous re-bin

    /// § Design "Injection": a direct `timeZoneDidChange(calendar:)` call resets the bin
    /// cache through `DayBinCache.reset()`, which "never calls the handler" — so it must
    /// re-bin exactly once, never a second time moments later.
    func testATimeZoneDidChangeNeverSchedulesASecondAsynchronousRebin() async throws {
        try writeRollout(responsesAt: [at(daysAgo: 2, hour: 12)], named: "no-double")
        let aggregator = CodexUsageAggregator(rootURL: tree.sessions, calendar: utc, center: NotificationCenter())
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
    /// sums them." Two responses of one UTC day, the earlier one folded out from under
    /// the later one by a cutoff that sits between them.
    func testSessionsSumsBothTiersWhenOneCivilDayHasAnEntryInEach() async throws {
        let earlier = at(daysAgo: 2, hour: 6)
        let later = at(daysAgo: 2, hour: 18)
        try writeRollout(responsesAt: [earlier, later], named: "split")
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let day = utc.startOfDay(for: earlier)
        let before = await aggregator.sessions(from: day, to: day)
        XCTAssertEqual(before.first?.turns, 2, "precondition: both responses are recent, on one day")

        await aggregator.foldTurns(olderThan: earlier.addingTimeInterval(3_600))

        let stillRecent = await aggregator.usage(from: later.addingTimeInterval(-1), to: later.addingTimeInterval(1))
        XCTAssertEqual(stillRecent.turns, 1, "precondition: the later response is still in recentTurns")
        let chats = await aggregator.sessions(from: day, to: day)
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        XCTAssertEqual(chat.days.map(\.day), [day], "one civil day, entries in both tiers merged into one row")
        XCTAssertEqual(chat.turns, 2, "the folded response and the still-recent one both count")
        XCTAssertEqual(chat.tokens.output, 200)
    }

    // MARK: - What a real re-bin leaves alone

    /// § Packages 3, exercised with a sub-agent thread: `models` and `agents` stay
    /// byte-for-byte equal after `timeZoneDidChange` moves the chat's days.
    func testARealRebinLeavesModelsAndAgentsExactlyEqual() async throws {
        let mainAt = at(daysAgo: 2, hour: 9)
        let agentAt = mainAt.addingTimeInterval(300)
        try writeRollout(responsesAt: [mainAt], named: "rebin-main")
        try writeSubagentRollout(at: agentAt)
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let day = utc.startOfDay(for: mainAt)
        let beforeSessions = await aggregator.sessions(from: day, to: day)
        let before = try XCTUnwrap(beforeSessions.first { $0.id == sessionID })
        XCTAssertEqual(before.agents.count, 1, "precondition: one sub-agent thread")

        await aggregator.timeZoneDidChange(calendar: plus5h30)

        let newDay = plus5h30.startOfDay(for: mainAt)
        let afterSessions = await aggregator.sessions(from: newDay, to: newDay)
        let after = try XCTUnwrap(afterSessions.first { $0.id == sessionID })
        XCTAssertEqual(after.models, before.models)
        XCTAssertEqual(after.agents, before.agents)
    }

    // MARK: - Repricing and the recent tier, per day

    /// A stronger form of the executor's own repricing test: the folded day of a long
    /// chat keeps the dollars it had (none — no rate at ingest time), while the recent
    /// day's dollars follow the new price table at once, checked per day rather than
    /// only through the chat's aggregate `usage(from:to:)`.
    func testCodexRepricingRebuildsOnlyTheRecentDaysDollars() async throws {
        let foldedAt = at(daysAgo: 32, hour: 1)
        let recentAt = at(daysAgo: 2, hour: 12)
        try writeRollout(responsesAt: [foldedAt, recentAt], named: "repriced")
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let unpriced = await aggregator.sessions(from: recentAt, to: recentAt)
        XCTAssertNil(unpriced.first?.tokens.cost, "precondition: no rate yet, no dollars")

        ModelPricing.updateDynamic(["gpt-5.6": terra])
        await aggregator.refresh()

        let foldedDay = await aggregator.sessions(from: foldedAt, to: foldedAt)
        XCTAssertNil(
            foldedDay.first?.days.first?.tokens.cost,
            "the folded day keeps the dollars it was read with: none"
        )
        let recentDay = await aggregator.sessions(from: recentAt, to: recentAt)
        let recentCost = try XCTUnwrap(recentDay.first?.days.first?.tokens.cost).total
        XCTAssertGreaterThan(recentCost, 0, "the recent day's response is priced again at once")
    }
}
