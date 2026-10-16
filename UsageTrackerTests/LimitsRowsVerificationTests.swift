import XCTest
@testable import Omelette

/// The ranked list and the rows under it, at the edges: limit-analytics spec (2026-10-16)
/// § The tab, items 2 and 3 (ranked rows, top 8 with "Show all", Outside this Mac last when
/// above 0, "< 0.1 %", Outside whole points on Claude) and § Accounts without percent
/// windows (no Outside on pay as you go; a spend limit's Outside is dollars over the limit).
final class LimitsRowsVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let locale = Locale(identifier: "en_GB")

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    private var week: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }

    private func names(_ providerID: String, _ slug: String) -> String { slug }

    private func chatRows(_ chats: [ChatShare], showsAll: Bool = false, zone: String = "UTC") -> LimitsRankedRows {
        LimitsRules.chatRows(
            of: Fixture.limitShare(window: week, chats: chats), serviceID: "claude", showsAll: showsAll,
            calendar: calendar(zone), locale: locale, projectName: names
        )
    }

    private func chats(_ count: Int, project: (Int) -> String = { _ in "alpha" }) -> [ChatShare] {
        (0..<count).map {
            Fixture.chatShare(
                id: "chat-\($0)", title: "Chat \($0)", project: project($0),
                points: Double(count - $0), cost: Double(count - $0), lastAt: now
            )
        }
    }

    // MARK: - Exactly 8 or 9 chats

    func testEightChatsAreAllShownWithNoShowAll() {
        let rows = chatRows(chats(8))
        XCTAssertEqual(rows.rows.count, 8)
        XCTAssertEqual(rows.total, 8)
        XCTAssertFalse(LimitsRules.canShowAll(count: rows.total))
    }

    func testNineChatsShowEightAndOfferAllNine() {
        let capped = chatRows(chats(9))
        XCTAssertEqual(capped.rows.map(\.id), (0..<8).map { "chat-\($0)" })
        XCTAssertEqual(capped.total, 9)
        XCTAssertTrue(LimitsRules.canShowAll(count: capped.total))
        XCTAssertEqual(LimitsCopy.showAll(count: capped.total, expanded: false), "Show all (9)")
        let all = chatRows(chats(9), showsAll: true)
        XCTAssertEqual(all.rows.map(\.id), (0..<9).map { "chat-\($0)" })
        XCTAssertEqual(all.total, 9)
        XCTAssertEqual(LimitsCopy.showAll(count: all.total, expanded: true), "Show fewer")
    }

    func testNineChatsNameAndFormatOnlyTheEightShown() {
        var asked = 0
        let capped = LimitsRules.chatRows(
            of: Fixture.limitShare(window: week, chats: chats(9)), serviceID: "claude", showsAll: false,
            calendar: calendar("UTC"), locale: locale
        ) { _, slug in
            asked += 1
            return slug
        }
        XCTAssertEqual(capped.rows.count, 8)
        XCTAssertEqual(asked, 8, "the ninth chat's project is never named")
    }

    func testAShareWithNoChatsHasNoRowsAndNoShowAll() {
        let none = chatRows([])
        XCTAssertEqual(none, LimitsRankedRows(rows: [], total: 0))
        XCTAssertFalse(LimitsRules.canShowAll(count: 0))
        XCTAssertFalse(LimitsRules.canShowAll(count: 1))
    }

    func testShowAllDoesNotCapAThousandChats() {
        let all = chatRows(chats(1_000), showsAll: true)
        XCTAssertEqual(all.rows.count, 1_000)
        XCTAssertEqual(LimitsCopy.showAll(count: all.total, expanded: false), "Show all (1,000)")
    }

    func testOnlyTheShownProjectsAreNamedAndFormatted() {
        let share = Fixture.limitShare(window: week, chats: chats(9, project: { "project-\($0)" }))
        var asked: [String] = []
        let capped = LimitsRules.projectRows(of: share, serviceID: "codex", showsAll: false) { provider, slug in
            asked.append("\(provider)/\(slug)")
            return slug
        }
        XCTAssertEqual(capped.rows.count, 8)
        XCTAssertEqual(capped.total, 9)
        XCTAssertEqual(asked.count, 8, "the ninth project is never named")
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("codex/") }, "the decoder is told the provider")
    }

    // MARK: - Ties and the order of the ranking

    func testRowsKeepTheSharesOrderNotTheOrderOfTheirDollarsOrNames() {
        let ranked = [
            Fixture.chatShare(id: "chat-z", title: "Zeta", points: 4.04, cost: 10, lastAt: now),
            Fixture.chatShare(id: "chat-a", title: "Alpha", points: 4.01, cost: 900, lastAt: now),
            Fixture.chatShare(id: "chat-m", title: "Mid", points: 0.04, cost: 3, lastAt: now),
            Fixture.chatShare(id: "chat-0", title: "Nothing", points: 0, cost: 0, lastAt: now),
        ]
        let rows = chatRows(ranked)
        XCTAssertEqual(rows.rows.map(\.id), ["chat-z", "chat-a", "chat-m", "chat-0"])
        XCTAssertEqual(rows.rows.map(\.share), ["≈ 4.0 %", "≈ 4.0 %", "< 0.1 %", "< 0.1 %"])
        XCTAssertEqual(rows.rows.map(\.dollars), ["$10", "$900", "$3.00", "$0.00"])
    }

    func testEqualChatsKeepTheOrderTheyWereRankedIn() {
        let tied = (0..<10).map {
            Fixture.chatShare(id: "chat-\(9 - $0)", title: "Same", points: 1, cost: 10, lastAt: now)
        }
        XCTAssertEqual(chatRows(tied).rows.map(\.id), (0..<8).map { "chat-\(9 - $0)" })
    }

    func testProjectsTieOnPointsThenDollarsThenName() {
        func chat(_ id: String, project: String, points: Double, cost: Double) -> ChatShare {
            Fixture.chatShare(id: id, title: id, project: project, points: points, cost: cost, lastAt: now)
        }
        let share = Fixture.limitShare(window: week, chats: [
            chat("c1", project: "p-b", points: 2, cost: 5),
            chat("c2", project: "p-a", points: 2, cost: 5),
            chat("c3", project: "p-dear", points: 2, cost: 9),
            chat("c4", project: "p-big", points: 3, cost: 1),
        ])
        let rows = LimitsRules.projectRows(of: share, serviceID: "claude", showsAll: true, projectName: names)
        XCTAssertEqual(rows.rows.map(\.id), ["p-big", "p-dear", "p-a", "p-b"])
    }

    func testAProjectCountsItsChatsInTheSingularAndWithThousands() {
        XCTAssertEqual(LimitsCopy.chatCount(0), "0 chats")
        XCTAssertEqual(LimitsCopy.chatCount(1), "1 chat")
        XCTAssertEqual(LimitsCopy.chatCount(2), "2 chats")
        XCTAssertEqual(LimitsCopy.chatCount(1_000), "1,000 chats")
        let share = Fixture.limitShare(window: week, chats: chats(1_000))
        XCTAssertEqual(
            LimitsRules.projectRows(of: share, serviceID: "claude", showsAll: false, projectName: names).rows.map(\.subtitle),
            ["1,000 chats"]
        )
    }

    // MARK: - A nameless chat and the day it ran

    func testABlankTitleReadsAsAMissingOne() {
        for blank in ["", "  ", "\n\t"] {
            let row = chatRows([Fixture.chatShare(id: "chat-a", title: blank, points: 1, cost: 1, lastAt: now)]).rows[0]
            XCTAssertEqual(row.title, "-Users-tester-Projects-alpha · 6 Sep", "title \"\(blank)\"")
        }
    }

    func testTheDayOfANamelessChatFollowsTheCalendarNotUTC() {
        // 2026-09-07 03:00 UTC is still 6 September in Los Angeles.
        let late = Date(timeIntervalSince1970: 1_788_696_000 + 15 * 3_600)
        let chat = Fixture.chatShare(id: "chat-a", points: 1, cost: 1, lastAt: late)
        XCTAssertTrue(chatRows([chat], zone: "UTC").rows[0].title.hasSuffix("7 Sep"))
        XCTAssertTrue(chatRows([chat], zone: "America/Los_Angeles").rows[0].title.hasSuffix("6 Sep"))
    }

    // MARK: - Outside this Mac on a Claude subscription

    private func outsideRow(_ points: Double, mode: LimitMode = .subscription, serviceID: String = "claude") -> [LimitsRow] {
        LimitsRules.tailRows(of: Fixture.limitShare(window: week, outside: points), mode: mode, serviceID: serviceID)
    }

    func testOutsideAtAHalfPointRoundsUpToOneWholePoint() {
        XCTAssertEqual(outsideRow(0.5).map(\.share), ["≈ 1 %"])
        XCTAssertEqual(outsideRow(1.5).map(\.share), ["≈ 2 %"])
        XCTAssertEqual(outsideRow(2.49).map(\.share), ["≈ 2 %"])
        XCTAssertEqual(outsideRow(2).map(\.share), ["≈ 2 %"])
    }

    func testAnOutsideRowOnClaudeNeverReadsZeroPercent() {
        // "Outside this Mac last when above 0" (§ The tab, item 3): a row that is drawn says
        // there is something outside, so a share of 0.4 or of float residue is not "≈ 0 %".
        for points in [0.4, 0.04, 1e-12] {
            XCTAssertTrue(
                outsideRow(points).allSatisfy { $0.share != "≈ 0 %" },
                "outside \(points) on a Claude subscription: \(outsideRow(points).map(\.share))"
            )
        }
    }

    func testNothingOutsideDrawsNoRowAtAnyMode() {
        XCTAssertEqual(outsideRow(0), [])
        XCTAssertEqual(outsideRow(-0.0), [])
        XCTAssertEqual(outsideRow(-3), [])
        XCTAssertEqual(outsideRow(0, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 100)), [])
    }

    func testOutsideKeepsItsDecimalOnCodexAndOnASpendLimit() {
        XCTAssertEqual(outsideRow(0.4, serviceID: "codex").map(\.share), ["≈ 0.4 %"])
        XCTAssertEqual(outsideRow(0.5, serviceID: "codex").map(\.share), ["≈ 0.5 %"])
        XCTAssertEqual(outsideRow(0.04, serviceID: "codex").map(\.share), ["< 0.1 %"])
        XCTAssertEqual(
            outsideRow(0.4, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 100)).map(\.share), ["≈ 0.4 %"]
        )
        XCTAssertEqual(outsideRow(7.25, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 100)).map(\.share).count, 1)
    }

    func testOutsideNeverCarriesDollarsAndIsOneRowWhoseIdIsOutside() {
        for serviceID in ["claude", "codex"] {
            let rows = outsideRow(3, serviceID: serviceID)
            XCTAssertEqual(rows.map(\.id), ["outside"])
            XCTAssertEqual(rows.map(\.dollars), [""])
            XCTAssertEqual(rows.map(\.title), ["Outside this Mac"])
        }
    }

    func testTheSubtitleNamesWhereTheUseCameFromPerProvider() {
        XCTAssertEqual(outsideRow(3, serviceID: "claude").map(\.subtitle), ["claude.ai, the desktop app or another machine"])
        XCTAssertEqual(outsideRow(3, serviceID: "codex").map(\.subtitle), ["another Codex client or another machine"])
        XCTAssertFalse(LimitsCopy.outsideSubtitle(serviceID: "codex").contains("claude"))
        XCTAssertFalse(LimitsCopy.outsideSubtitle(serviceID: "claude").contains("Codex"))
        XCTAssertEqual(LimitsCopy.outsideSubtitle(serviceID: "grok"), "another app or another machine")
    }

    func testPayAsYouGoSharesFromTheRuleDrawNoOutsideRow() throws {
        // § Accounts without percent windows: Outside is "no: the budget is measured on this Mac's spend".
        let log = TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 412)])
        for budget in [500.0, nil] {
            let request = LimitShareRequest(
                mode: .payAsYouGo(weeklyBudget: budget),
                period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now), bucketID: nil, livePercent: nil
            )
            let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
            XCTAssertEqual(LimitsRules.tailRows(of: share, mode: request.mode, serviceID: "claude"), [], "budget \(String(describing: budget))")
        }
    }

    func testASpendLimitsOutsideFromTheRuleIsTheServersCreditsOverTheLimitWithItsDecimal() throws {
        let log = TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 1_000)])
        let mode = LimitMode.spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)
        let request = LimitShareRequest(
            mode: mode, period: LimitWindow(start: Date(timeIntervalSince1970: 1_788_220_800), end: now),
            bucketID: nil, livePercent: nil
        )
        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(LimitsRules.tailRows(of: share, mode: mode, serviceID: "claude").map(\.share), ["≈ 12.0 %"])
    }

    func testEarlierThisMonthComesBeforeOutsideAndReadsAFloorBelowATenth() {
        let share = Fixture.limitShare(
            window: week, outside: 3, earlier: EarlierLocalShare(points: 0.04, cost: 0.8)
        )
        let rows = LimitsRules.tailRows(of: share, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 100), serviceID: "claude")
        XCTAssertEqual(rows.map(\.id), ["earlier", "outside"])
        XCTAssertEqual(rows.first?.share, "< 0.1 %")
        XCTAssertEqual(rows.first?.dollars, "$0.80")
    }
}
