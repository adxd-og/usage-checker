import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Problem 1,
/// § Design ("Rule", "Codex", "Injection") and § Packages 3: a Codex chat's days are
/// two tiers told apart by where a response is — `recentByDay` for the turns in
/// `recentTurns`, `byDay` for every other — and follow the time zone the aggregator is
/// told about without counting a response twice. Rollout lines come from
/// `CodexRolloutFixtures` (Codex CLI 0.153.4 shapes). The aggregator takes its 31-day
/// window from the real clock, so responses are placed relative to it, pinned to UTC:
/// 30 days back is recent and 32 days back is folded whatever the hour.
final class CodexChatRebinTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now = Date()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let sessionID = "01a0c3d2-5e7f-7a18-9b4c-2d6e8f0a1b35"
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
    private var plus3: Calendar { Self.calendar(secondsFromGMT: 3 * 3600) }
    private var minus3: Calendar { Self.calendar(secondsFromGMT: -3 * 3600) }

    /// The live price table is process-global: every test starts and ends with it empty,
    /// as `CodexRepricingTests` does.
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexChatRebinTests-\(UUID().uuidString)", isDirectory: true)
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

    /// One rollout of this chat with a `token_usage_record` at each instant: 1_000 in
    /// (400 of them cached) and 100 out, 1_100 tokens a response.
    private func writeRollout(responsesAt instants: [Date]) throws {
        let opened = instants.min()!
        var lines = [
            CodexRollout.sessionMeta(sessionID: sessionID, cwd: cwd, at: opened.addingTimeInterval(-60)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: opened.addingTimeInterval(-30)),
        ]
        for (i, instant) in instants.enumerated() {
            lines.append(CodexRollout.record(
                at: instant, threadID: sessionID, responseID: "resp_rebin_\(i)",
                input: 1_000, cached: 400, output: 100, reasoning: 30
            ))
        }
        try tree.writeRollout(lines, named: "rollout-2026-09-06T02-09-23-\(sessionID).jsonl")
    }

    /// The chat's response and token counts over everything it holds (see the Claude
    /// twin in `JSONLChatRebinTests`).
    private func totals(_ aggregator: CodexUsageAggregator) async throws -> (turns: Int, tokens: Int, mainTokens: Int) {
        let chats = await aggregator.sessions(from: at(daysAgo: 40, hour: 0), to: Date())
        let chat = try XCTUnwrap(chats.first { $0.id == sessionID })
        return (chat.turns, chat.tokens.total, chat.mainTokens.total)
    }

    // MARK: - Told the zone moved

    /// § Packages 3 (i): a UTC-midnight day was not the UTC+3 midnight of the same date,
    /// so `summary` returned nil for the range asking for it.
    func testAChatReadInUTCIsFoundOnItsDateAfterTheZoneMovesToUTCPlus3() async throws {
        let turnAt = at(daysAgo: 2, hour: 12)
        try writeRollout(responsesAt: [turnAt])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()

        await aggregator.timeZoneDidChange(calendar: plus3)

        let day = plus3.startOfDay(for: turnAt)
        let chats = await aggregator.sessions(from: day, to: day)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), [day])
        XCTAssertEqual(chats.first?.turns, 1)
        XCTAssertEqual(chats.first?.tokens.total, 1_100)
    }

    /// 22:30 UTC is the next date at UTC+3: after the change the chat's day is the one
    /// Activity bins the same response into.
    func testALateEveningResponseMovesToActivitysDateWhenTheZoneMovesEast() async throws {
        let turnAt = at(daysAgo: 3, hour: 22, minute: 30)
        try writeRollout(responsesAt: [turnAt])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()

        await aggregator.timeZoneDidChange(calendar: plus3)

        let activityDays = await aggregator.breakdown(now: now).daily.map(\.day)
        XCTAssertEqual(activityDays, [plus3.startOfDay(for: turnAt)], "precondition: Activity bins the response at UTC+3")
        let chats = await aggregator.sessions(from: turnAt, to: turnAt)
        XCTAssertEqual(chats.first?.days.map(\.day), activityDays)
    }

    /// § Packages 3 (ii), Claude's (iv) for Codex: responses 32 days back (folded) and
    /// 30 days back (recent), both within three hours of a midnight, and a recent one.
    /// The chat's responses and tokens stay what they were across UTC+3, UTC−3, and a
    /// fold of the 30-day response after them (through `foldTurns(olderThan:)`, a
    /// cutoff one second past it).
    func testAChatKeepsItsTotalsAcrossZoneChangesAndAFold() async throws {
        let lateAt = at(daysAgo: 30, hour: 22, minute: 30)
        try writeRollout(responsesAt: [at(daysAgo: 32, hour: 1), lateAt, at(daysAgo: 2, hour: 12)])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let lateWhileRecent = await aggregator.usage(
            from: lateAt.addingTimeInterval(-1), to: lateAt.addingTimeInterval(1)
        )
        XCTAssertEqual(lateWhileRecent.turns, 1, "precondition: the 30-day response is among the recent turns")
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
        XCTAssertEqual(lateAfterFold.turns, 0, "the 30-day response has left the recent turns")
        let afterFold = try await totals(aggregator)

        for (label, t) in [("UTC+3", afterEast), ("UTC−3", afterWest), ("the fold", afterFold)] {
            XCTAssertEqual(t.turns, before.turns, label)
            XCTAssertEqual(t.tokens, before.tokens, label)
            XCTAssertEqual(t.mainTokens, before.mainTokens, label)
        }
    }

    /// A change that moves nothing leaves the chat exactly as it was, folded day included.
    func testAChangeThatMovesNothingLeavesTheChatAsItWas() async throws {
        try writeRollout(responsesAt: [
            at(daysAgo: 40, hour: 12), at(daysAgo: 2, hour: 12), at(daysAgo: 1, hour: 22, minute: 30),
        ])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let from = at(daysAgo: 41, hour: 0)
        let before = await aggregator.sessions(from: from, to: now)
        XCTAssertEqual(before.first?.days.count, 3, "precondition: a folded day and two recent ones")

        await aggregator.timeZoneDidChange(calendar: utc)

        let after = await aggregator.sessions(from: from, to: now)
        XCTAssertEqual(after, before)
    }

    // MARK: - A new price table

    /// A chat that started before the window is not recorded again when the price table
    /// changes, but its recent days are a function of `recentTurns` and follow the new
    /// prices at once — not at the next re-bin or fold, when its dollars would jump. The
    /// response 32 days back keeps the dollars it was read with (none: no rate yet).
    func testALongChatsRecentDayFollowsANewPriceTableAtOnce() async throws {
        let recentAt = at(daysAgo: 2, hour: 12)
        try writeRollout(responsesAt: [at(daysAgo: 32, hour: 1), recentAt])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let unpriced = await aggregator.sessions(from: recentAt, to: recentAt)
        XCTAssertNil(unpriced.first?.tokens.cost, "precondition: no rate yet, no dollars")

        ModelPricing.updateDynamic(["gpt-5.6": terra])
        await aggregator.refresh()

        let turnCost = await aggregator.usage(
            from: recentAt.addingTimeInterval(-1), to: recentAt.addingTimeInterval(1)
        ).cost
        XCTAssertEqual(turnCost, 0.0018, accuracy: 1e-12, "precondition: the recent response is priced again")
        let repriced = await aggregator.sessions(from: recentAt, to: recentAt)
        XCTAssertEqual(try XCTUnwrap(repriced.first?.tokens.cost).total, turnCost, accuracy: 1e-12)

        await aggregator.timeZoneDidChange(calendar: utc)

        let afterRebin = await aggregator.sessions(from: recentAt, to: recentAt)
        XCTAssertEqual(
            try XCTUnwrap(afterRebin.first?.tokens.cost).total, turnCost, accuracy: 1e-12,
            "a re-bin that moves nothing moves no dollars either"
        )
    }
}
