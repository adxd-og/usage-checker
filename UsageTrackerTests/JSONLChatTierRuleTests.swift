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
}
