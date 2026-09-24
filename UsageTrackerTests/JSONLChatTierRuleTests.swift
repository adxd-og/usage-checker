import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design ("Rule",
/// "Claude") and § Packages 2 (iii) and (v): a Claude chat's days are two tiers told
/// apart by where a turn is — `recentDays` for the turns in `recentTurns`,
/// `foldedDays` for every other — so a re-bin rebuilds one and re-keys the other and
/// never counts a turn twice. Values are built with the aggregate's own
/// `init(projectSlug:at:)` and `add(_:on:recent:)`, the way a transcript fills them.
/// Fixed epochs; every calendar carries its zone.
final class JSONLChatTierRuleTests: XCTestCase {
    private let sonnet = "claude-sonnet-4-5"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let sessionID = "5b0e3c1a-7d42-4f96-a8e1-2c9d6b4f0a37"
    private let agentID = "a0f3c9e1b7d24a615"

    private let aug10Morning = Date(timeIntervalSince1970: 1_786_352_400)     // 2026-08-10 09:00 UTC
    private let aug10Afternoon = Date(timeIntervalSince1970: 1_786_374_000)   // 2026-08-10 15:00 UTC
    private let aug10UTC = Date(timeIntervalSince1970: 1_786_320_000)         // 2026-08-10 00:00 UTC
    private let aug10Plus3 = Date(timeIntervalSince1970: 1_786_309_200)       // 2026-08-10 00:00 +03:00
    private let sep20Morning = Date(timeIntervalSince1970: 1_789_894_800)     // 2026-09-20 09:00 UTC
    private let sep20Late = Date(timeIntervalSince1970: 1_789_943_400)        // 2026-09-20 22:30 UTC
    private let sep20UTC = Date(timeIntervalSince1970: 1_789_862_400)         // 2026-09-20 00:00 UTC
    private let sep21Plus3 = Date(timeIntervalSince1970: 1_789_938_000)       // 2026-09-21 00:00 +03:00

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus3: Calendar { Self.calendar(secondsFromGMT: 3 * 3600) }

    private func turn(_ id: String, at date: Date, input: Int, agentID: String? = nil) -> CLITurn {
        CLITurn(
            id: id,
            timestamp: date,
            model: sonnet,
            tokens: TokenBreakdown(input: input, output: input / 10).priced(model: sonnet),
            projectSlug: alphaSlug,
            sessionID: sessionID,
            agentID: agentID,
            agentKind: agentID == nil ? nil : "planner",
            effort: "xhigh"
        )
    }

    // MARK: - Filing

    func testARecentTurnGoesToTheRecentTierAndAnOldOneToTheFoldedTier() {
        let old = turn("msg_01TierOld00000000000000", at: aug10Morning, input: 1_000)
        let recent = turn("msg_01TierNew00000000000000", at: sep20Late, input: 2_000)
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: old.timestamp)
        agg.add(old, on: utc.startOfDay(for: old.timestamp), recent: false)
        agg.add(recent, on: utc.startOfDay(for: recent.timestamp), recent: true)

        XCTAssertEqual(agg.foldedDays.map(\.day), [aug10UTC])
        XCTAssertEqual(agg.recentDays.map(\.day), [sep20UTC])
        XCTAssertEqual(agg.days.map(\.day), [aug10UTC, sep20UTC], "a range reads both tiers")
        XCTAssertEqual(agg.byModel.values.map(\.turns).reduce(0, +), 2, "both count towards the model rows")
    }

    /// A zone change or a fold part-way through a day gives it a share in each tier;
    /// the day a range reads is their sum.
    func testADayWithAShareInEachTierIsReadAsTheirSum() {
        let morning = turn("msg_01TierShareA0000000000", at: sep20Morning, input: 1_000)
        let evening = turn("msg_01TierShareB0000000000", at: sep20Late, input: 2_000)
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: morning.timestamp)
        agg.add(morning, on: sep20UTC, recent: false)
        agg.add(evening, on: sep20UTC, recent: true)

        XCTAssertEqual(agg.days.map(\.day), [sep20UTC])
        XCTAssertEqual(agg.days.map(\.turns), [2])
        XCTAssertEqual(agg.days.first?.tokens.input, 3_000)
        XCTAssertEqual(agg.days.first?.mainTokens.input, 3_000)
    }

    // MARK: - The folded tier across zones

    /// § Packages 2 (iii). Two turns of 10 August, one filed before the zone moved
    /// (UTC's midnight) and one after (UTC+3's): both keys name that date, so the
    /// re-key files them as one day. The recent tier is never re-keyed.
    func testAFoldedDayIsReKeyedByTheMidpointRuleAndMergedWithTheNeighbourOnItsKey() {
        let morning = turn("msg_01TierOldA000000000000", at: aug10Morning, input: 1_000)
        let afternoon = turn("msg_01TierOldB000000000000", at: aug10Afternoon, input: 2_000)
        let recent = turn("msg_01TierOldC000000000000", at: sep20Late, input: 4_000)
        let plus3 = self.plus3
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: morning.timestamp)
        agg.add(morning, on: utc.startOfDay(for: morning.timestamp), recent: false)
        agg.add(afternoon, on: plus3.startOfDay(for: afternoon.timestamp), recent: false)
        agg.add(recent, on: utc.startOfDay(for: recent.timestamp), recent: true)
        XCTAssertEqual(agg.foldedDays.count, 2, "precondition: two midnights of one date")

        let rekeyed = agg.rekeyingFolded { DayRekey.midpoint($0, calendar: plus3) }

        XCTAssertEqual(rekeyed.foldedDays.map(\.day), [aug10Plus3])
        XCTAssertEqual(rekeyed.foldedDays.map(\.turns), [2])
        XCTAssertEqual(rekeyed.foldedDays.first?.tokens.input, 3_000)
        XCTAssertEqual(rekeyed.foldedDays.first?.mainTokens.input, 3_000)
        XCTAssertEqual(rekeyed.recentDays, agg.recentDays)
    }

    // MARK: - The recent tier

    /// A 22:30 UTC turn is the 20th in UTC and the 21st at UTC+3. The recent tier is
    /// made again from the turn in the new zone, and the old zone's key is gone.
    func testTheRecentTierIsRebuiltFromTheChatsTurnsInTheNewZone() {
        let late = turn("msg_01TierLate000000000000", at: sep20Late, input: 1_000)
        let plus3 = self.plus3
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: late.timestamp)
        agg.add(late, on: sep20UTC, recent: true)

        let rebuilt = agg.rebuildingRecentDays(from: [late], dayStart: { plus3.startOfDay(for: $0) })

        XCTAssertEqual(rebuilt.recentDays, [.init(day: sep21Plus3, turns: 1, tokens: late.tokens, mainTokens: late.tokens)])
        XCTAssertEqual(rebuilt.foldedDays, agg.foldedDays)
    }

    /// A turn leaving `recentTurns` moves its share of the day into the folded tier and
    /// out of the recent one: the day keeps the turn once.
    func testAFoldedTurnLeavesTheRecentTierAndJoinsTheFoldedOne() {
        let first = turn("msg_01TierFoldA00000000000", at: sep20Morning, input: 1_000)
        let second = turn("msg_01TierFoldB00000000000", at: sep20Late, input: 2_000)
        let utc = self.utc
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: first.timestamp)
        agg.add(first, on: sep20UTC, recent: true)
        agg.add(second, on: sep20UTC, recent: true)

        agg.addFolded(first, on: sep20UTC)
        let after = agg.rebuildingRecentDays(from: [second], dayStart: { utc.startOfDay(for: $0) })

        XCTAssertEqual(after.foldedDays, [.init(day: sep20UTC, turns: 1, tokens: first.tokens, mainTokens: first.tokens)])
        XCTAssertEqual(after.recentDays, [.init(day: sep20UTC, turns: 1, tokens: second.tokens, mainTokens: second.tokens)])
        XCTAssertEqual(after.days.map(\.turns), [2])
        XCTAssertEqual(after.days.first?.tokens.input, 3_000)
        XCTAssertEqual(after.byModel, agg.byModel, "the model rows took the turn when it was read")
    }

    // MARK: - What a re-bin leaves alone

    /// § Packages 2 (v): the two steps `rebinChats()` applies to each chat — the folded
    /// tier re-keyed, the recent one rebuilt — leave the agents and the model rows
    /// exactly as they were.
    func testARebinLeavesTheModelRowsAndTheAgentsExactlyAsTheyWere() {
        let old = turn("msg_01TierVOld000000000000", at: aug10Morning, input: 500)
        let main = turn("msg_01TierVMain00000000000", at: sep20Morning, input: 1_000)
        let agent = turn("msg_01TierVAgent0000000000", at: sep20Morning.addingTimeInterval(300), input: 2_000, agentID: agentID)
        let utc = self.utc
        let plus3 = self.plus3
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: old.timestamp)
        agg.add(old, on: utc.startOfDay(for: old.timestamp), recent: false)
        agg.add(main, on: utc.startOfDay(for: main.timestamp), recent: true)
        agg.add(agent, on: utc.startOfDay(for: agent.timestamp), recent: true)
        XCTAssertEqual(agg.agents.count, 1, "precondition: one sub-agent")

        let rebinned = agg
            .rekeyingFolded { DayRekey.midpoint($0, calendar: plus3) }
            .rebuildingRecentDays(from: [main, agent], dayStart: { plus3.startOfDay(for: $0) })

        XCTAssertEqual(rebinned.agents, agg.agents)
        XCTAssertEqual(rebinned.byModel, agg.byModel)
        XCTAssertEqual(rebinned.firstAt, agg.firstAt)
        XCTAssertEqual(rebinned.lastAt, agg.lastAt)
        XCTAssertEqual(rebinned.projectSlug, agg.projectSlug)
        XCTAssertEqual(rebinned.recentDays.first?.tokens.input, 3_000)
        XCTAssertEqual(rebinned.recentDays.first?.mainTokens.input, 1_000, "the main thread's share leaves the agent out")
    }

    /// Every launch re-bins a cache saved in the same zone: nothing may move.
    func testARebinInTheSameZoneChangesNoDay() {
        let old = turn("msg_01TierSameOld000000000", at: aug10Morning, input: 1_000)
        let recent = turn("msg_01TierSameNew000000000", at: sep20Late, input: 2_000)
        let utc = self.utc
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: old.timestamp)
        agg.add(old, on: utc.startOfDay(for: old.timestamp), recent: false)
        agg.add(recent, on: utc.startOfDay(for: recent.timestamp), recent: true)

        let rebinned = agg
            .rekeyingFolded { DayRekey.midpoint($0, calendar: utc) }
            .rebuildingRecentDays(from: [recent], dayStart: { utc.startOfDay(for: $0) })

        XCTAssertEqual(rebinned.foldedDays, agg.foldedDays)
        XCTAssertEqual(rebinned.recentDays, agg.recentDays)
    }

    // MARK: - What the cache keeps

    /// Only the folded tier is saved, under the `days` key every version before 8 used;
    /// the recent tier comes back from `recentTurns`, never from the file.
    func testTheSavedChatCarriesItsFoldedDaysOnly() throws {
        let old = turn("msg_01TierSavedOld00000000", at: aug10Morning, input: 1_000)
        let recent = turn("msg_01TierSavedNew00000000", at: sep20Late, input: 2_000)
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: old.timestamp)
        agg.add(old, on: aug10UTC, recent: false)
        agg.add(recent, on: sep20UTC, recent: true)

        let data = try JSONEncoder().encode(agg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["days"] as? [Any])?.count, 1)
        XCTAssertNil(json["recentDays"])
        XCTAssertNil(json["foldedDays"])

        let decoded = try JSONDecoder().decode(JSONLAggregator.SessionAgg.self, from: data)
        XCTAssertEqual(decoded.foldedDays, agg.foldedDays)
        XCTAssertTrue(decoded.recentDays.isEmpty)
    }

    // MARK: - Converting a v7 chat

    /// 2026-09-21 00:00 UTC, and 09:00 the same day.
    private let sep21UTC = Date(timeIntervalSince1970: 1_789_948_800)
    private let sep21Morning = Date(timeIntervalSince1970: 1_789_981_200)

    private var vilnius: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vilnius")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// A chat as a v7 snapshot decodes: every day, the recent turns' included, in the
    /// folded tier — the v7 `days` key is the v8 `foldedDays` — each turn on its day in
    /// `calendar` (UTC unless a test says otherwise).
    private func v7Chat(_ turns: [CLITurn], filedIn calendar: Calendar? = nil) -> JSONLAggregator.SessionAgg {
        let zone = calendar ?? utc
        var agg = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: turns[0].timestamp)
        for t in turns { agg.add(t, on: zone.startOfDay(for: t.timestamp), recent: false) }
        return agg
    }

    /// Spec § Design, "Claude" (the v7 conversion): a recent turn leaves the saved day
    /// with the latest key at or before it, which keeps the folded turn beside it.
    func testARecentTurnIsTakenOutOfTheLatestSavedDayAtOrBeforeIt() throws {
        let folded = turn("msg_01ConvKeep00000000000", at: sep20Morning, input: 1_000)
        let recent = turn("msg_01ConvTake00000000000", at: sep20Late, input: 2_000)
        let chat = v7Chat([folded, recent])

        let converted = chat.subtractingRecentTurns([recent])

        XCTAssertEqual(converted.foldedDays.map(\.day), [sep20UTC])
        XCTAssertEqual(converted.foldedDays.map(\.turns), [1])
        XCTAssertEqual(converted.foldedDays.first?.tokens.total, folded.tokens.total)
        XCTAssertEqual(converted.foldedDays.first?.mainTokens.total, folded.tokens.total)
        XCTAssertEqual(
            try XCTUnwrap(converted.foldedDays.first?.tokens.cost).total,
            try XCTUnwrap(folded.tokens.cost).total, accuracy: 1e-12
        )
        XCTAssertEqual(converted.byModel, chat.byModel, "the model rows are the chat's whole split and stay")
        XCTAssertEqual(converted.agents, chat.agents)
    }

    /// A turn at the next midnight is the next saved day's, never the one before it.
    func testATurnAtTheNextMidnightIsTakenOutOfTheNextSavedDay() {
        let earlier = turn("msg_01ConvEarlier000000000", at: sep20Morning, input: 1_000)
        let atMidnight = turn("msg_01ConvMidnight00000000", at: sep21UTC, input: 2_000)
        let chat = v7Chat([earlier, atMidnight])
        XCTAssertEqual(chat.foldedDays.count, 2, "precondition: the 20th and the 21st")

        let converted = chat.subtractingRecentTurns([atMidnight])

        XCTAssertEqual(converted.foldedDays, [chat.foldedDays[0]], "the 20th untouched, the 21st gone")
    }

    /// A sub-agent's turn gives back its turn and its tokens; the main thread's share
    /// never held it and stays as it was.
    func testASubAgentTurnLeavesTheMainThreadShareAlone() {
        let main = turn("msg_01ConvMain00000000000", at: sep20Morning, input: 1_000)
        let agent = turn(
            "msg_01ConvAgent0000000000", at: sep20Morning.addingTimeInterval(300), input: 2_000, agentID: agentID
        )
        let chat = v7Chat([main, agent])

        let converted = chat.subtractingRecentTurns([agent])

        XCTAssertEqual(converted.foldedDays.map(\.turns), [1])
        XCTAssertEqual(converted.foldedDays.first?.tokens.total, main.tokens.total)
        XCTAssertEqual(converted.foldedDays.first?.mainTokens, chat.foldedDays.first?.mainTokens)
    }

    /// A saved day whose only turn is recent has nothing left to fold: it goes.
    func testASavedDayWhoseLastTurnIsTakenOutIsRemoved() {
        let recent = turn("msg_01ConvOnly00000000000", at: sep20Late, input: 2_000)
        let chat = v7Chat([recent])

        let converted = chat.subtractingRecentTurns([recent])

        XCTAssertTrue(converted.foldedDays.isEmpty)
        XCTAssertTrue(converted.days.isEmpty)
    }

    /// A chat that changed zone while 2.7.0 ran: turns binned in UTC on the 20th (key
    /// 00:00 UTC) until the change, then in UTC+3 (key 21:00 UTC, the UTC+3 midnight of
    /// the 21st) — two keys 21 hours apart, their days overlapping. A turn at 21:30 UTC
    /// saved under the UTC key leaves the UTC+3 day, the latest key at or before it.
    /// That is the documented cost: one turn's share on the neighbouring day, and
    /// nothing below zero.
    func testAmongOverlappingKeysTheLatestAtOrBeforeTheTurnWins() {
        let morning = turn("msg_01ConvZoneA0000000000", at: sep20Morning, input: 1_000)
        let beforeChange = turn(
            "msg_01ConvZoneB0000000000", at: sep20UTC.addingTimeInterval(21.5 * 3600), input: 1_000
        )   // 2026-09-20 21:30 UTC, binned in UTC
        let afterChange = turn("msg_01ConvZoneC0000000000", at: sep20Late, input: 1_000)   // 22:30 UTC, binned at UTC+3
        var chat = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: morning.timestamp)
        chat.add(morning, on: sep20UTC, recent: false)
        chat.add(beforeChange, on: sep20UTC, recent: false)
        chat.add(afterChange, on: sep21Plus3, recent: false)
        XCTAssertEqual(chat.foldedDays.map(\.day), [sep20UTC, sep21Plus3], "precondition: keys 21 h apart")

        let converted = chat.subtractingRecentTurns([beforeChange])

        XCTAssertEqual(converted.foldedDays, [chat.foldedDays[0]], "the UTC+3 day gave it back; the UTC day is untouched")
    }

    /// 2026-10-25 in Vilnius has 25 hours (EEST falls back to EET). A turn at 23:30 is
    /// 24.5 hours after the day's saved midnight and still that day's: it leaves that
    /// day, not the next and not nothing.
    func testATurnInTheTwentyFifthHourOfAFallBackDayStaysOnItsDay() {
        let savedMidnight = Date(timeIntervalSince1970: 1_792_875_600)   // 2026-10-25 00:00 EEST
        let morning = turn(
            "msg_01ConvFallMorning00000", at: Date(timeIntervalSince1970: 1_792_918_800), input: 1_000
        )   // 11:00 EET
        let lateNight = turn(
            "msg_01ConvFallLate0000000", at: Date(timeIntervalSince1970: 1_792_963_800), input: 2_000
        )   // 23:30 EET
        XCTAssertEqual(vilnius.startOfDay(for: lateNight.timestamp), savedMidnight, "precondition: the same Vilnius day")
        XCTAssertGreaterThanOrEqual(
            lateNight.timestamp.timeIntervalSince(savedMidnight), 24 * 3600, "precondition: its 25th hour"
        )
        let chat = v7Chat([morning, lateNight], filedIn: vilnius)

        let converted = chat.subtractingRecentTurns([lateNight])

        XCTAssertEqual(converted.foldedDays.map(\.day), [savedMidnight])
        XCTAssertEqual(converted.foldedDays.map(\.turns), [1])
        XCTAssertEqual(converted.foldedDays.first?.tokens.total, morning.tokens.total)
    }

    /// A turn earlier than every saved key leaves the earliest day.
    func testATurnEarlierThanEverySavedDayLeavesTheEarliest() {
        let first = turn("msg_01ConvEarliestA0000000", at: sep20Morning, input: 1_000)
        let second = turn("msg_01ConvEarliestB0000000", at: sep21Morning, input: 1_000)
        let early = turn(
            "msg_01ConvEarliestC0000000", at: Date(timeIntervalSince1970: 1_789_819_200), input: 1_000
        )   // 2026-09-19 12:00 UTC
        let chat = v7Chat([first, second])

        let converted = chat.subtractingRecentTurns([early])

        XCTAssertEqual(converted.foldedDays, [chat.foldedDays[1]], "the 20th gave it back; the 21st is untouched")
    }

    /// A chat with no saved day has nothing to give back: the turn is passed over.
    func testAChatWithNoSavedDaysIsLeftAsItIs() {
        let recent = turn("msg_01ConvNoDays000000000", at: sep20Late, input: 1_000)
        var chat = JSONLAggregator.SessionAgg(projectSlug: alphaSlug, at: recent.timestamp)
        chat.add(recent, on: sep20UTC, recent: true)

        let converted = chat.subtractingRecentTurns([recent])

        XCTAssertTrue(converted.foldedDays.isEmpty)
        XCTAssertEqual(converted.recentDays, chat.recentDays)
        XCTAssertEqual(converted.byModel, chat.byModel)
    }

    /// Tokens given back beyond what a day holds take each counter to zero, never below:
    /// input, output, the dollars and the main thread's share alike.
    func testTokensGivenBackBeyondWhatADayHoldsFloorAtZero() throws {
        let a = turn("msg_01ConvFloorA000000000", at: sep20Morning, input: 1_000)
        let b = turn("msg_01ConvFloorB000000000", at: sep20Morning.addingTimeInterval(600), input: 1_000)
        let big = turn("msg_01ConvFloorBig0000000", at: sep20Late, input: 5_000)
        let chat = v7Chat([a, b])

        let converted = chat.subtractingRecentTurns([big])

        let day = try XCTUnwrap(converted.foldedDays.first)
        XCTAssertEqual(day.turns, 1)
        XCTAssertEqual(day.tokens.input, 0)
        XCTAssertEqual(day.tokens.output, 0)
        XCTAssertEqual(day.tokens.total, 0)
        XCTAssertEqual(day.mainTokens.total, 0)
        XCTAssertEqual(try XCTUnwrap(day.tokens.cost).total, 0, accuracy: 1e-12)
    }

    /// A day given back every turn, every token and every dollar is empty in every
    /// counter and is removed; a turn left with no day has nothing to give back and is
    /// passed over.
    func testADayEmptiedOfTurnsAndTokensIsRemovedAndATurnLeftWithNoDayGoesNoFurther() {
        let first = turn("msg_01ConvFirst0000000000", at: sep20Morning, input: 1_000)
        let second = turn("msg_01ConvSecond000000000", at: sep20Late, input: 2_000)
        let chat = v7Chat([first])

        let converted = chat.subtractingRecentTurns([first, second])

        XCTAssertTrue(converted.foldedDays.isEmpty)
        XCTAssertEqual(converted.byModel, chat.byModel)
    }

    /// A day that still holds tokens after its turns reach zero stays, with 0 turns and
    /// those tokens: a 2.7.0 cache re-keyed forward can hand a small recent turn to the
    /// neighbouring day, and dropping that day would erase a far larger folded remainder.
    /// Dollars are floating-point sums: a day whose turns and tokens are all zero but
    /// whose cost buckets keep a residue like 1e-19 is empty, so it is removed rather
    /// than shown as a $0.00 day with nothing in it.
    func testADayWithOnlyAFloatingPointDollarResidueIsEmpty() {
        var tokens = TokenBreakdown.zero
        tokens.cost = TokenCostBreakdown(input: 1e-19, output: 0, cacheRead: -1e-19, cacheWrite: 0)
        let day = JSONLAggregator.SessionAgg.DayTotals(day: sep20UTC, turns: 0, tokens: tokens, mainTokens: .zero)
        XCTAssertTrue(JSONLAggregator.SessionAgg.isEmpty(day))

        var real = TokenBreakdown.zero
        real.cost = TokenCostBreakdown(input: 0.01, output: 0, cacheRead: 0, cacheWrite: 0)
        let cent = JSONLAggregator.SessionAgg.DayTotals(day: sep20UTC, turns: 0, tokens: real, mainTokens: .zero)
        XCTAssertFalse(JSONLAggregator.SessionAgg.isEmpty(cent))
    }

    func testADayWhoseTurnsReachZeroWhileTokensRemainStaysWithZeroTurnsAndThoseTokens() throws {
        let folded = turn("msg_01ConvLarge0000000000", at: sep20Morning, input: 1_000)
        let recent = turn("msg_01ConvSmall0000000000", at: sep20Late, input: 10)
        let chat = v7Chat([folded])

        let converted = chat.subtractingRecentTurns([recent])

        let day = try XCTUnwrap(converted.foldedDays.first)
        XCTAssertEqual(converted.foldedDays.count, 1)
        XCTAssertEqual(day.day, sep20UTC)
        XCTAssertEqual(day.turns, 0)
        XCTAssertEqual(day.tokens.input, 990)
        XCTAssertEqual(day.tokens.output, 99)
        XCTAssertEqual(day.mainTokens.input, 990)
        XCTAssertGreaterThan(try XCTUnwrap(day.tokens.cost).total, 0)
    }
}
