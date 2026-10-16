import XCTest
@testable import Omelette

/// The rows under the ranked chats: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 3 ("Outside this Mac last when above 0"), item 2
/// (Outside is whole points on Claude), and § Accounts without percent windows (pay as
/// you go has no Outside; a spend limit's Outside is the server's credits minus this
/// Mac's spend; the "Earlier this month" row after the chats, before Outside; the cost
/// caption "API-list prices; your organisation's rate may differ").
final class LimitsTailRowsTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private var week: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }
    /// 2026-09-01 00:00 UTC to now.
    private var month: LimitWindow { LimitWindow(start: Date(timeIntervalSince1970: 1_788_220_800), end: now) }

    func testOutsideOnAClaudeSubscriptionIsWholePointsWithNoDollars() {
        let share = Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", points: 25, cost: 1_550, lastAt: now)],
            outside: 2
        )
        XCTAssertEqual(LimitsRules.tailRows(of: share, mode: .subscription, serviceID: "claude"), [
            LimitsRow(
                id: "outside", title: "Outside this Mac",
                subtitle: "claude.ai, the desktop app or another machine",
                share: "≈ 2 %", dollars: ""
            ),
        ])
    }

    func testOutsideOnCodexKeepsItsDecimal() {
        let outside = LimitsRules.tailRows(
            of: Fixture.limitShare(window: week, outside: 1.4), mode: .subscription, serviceID: "codex"
        )
        XCTAssertEqual(outside.map(\.share), ["≈ 1.4 %"])
        XCTAssertEqual(outside.map(\.subtitle), ["another Codex client or another machine"])
    }

    func testNothingOutsideThisMacHasNoRow() {
        let share = Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", points: 27, cost: 1_674, lastAt: now)]
        )
        XCTAssertEqual(LimitsRules.tailRows(of: share, mode: .subscription, serviceID: "claude"), [])
        XCTAssertEqual(
            LimitsRules.tailRows(of: share, mode: .payAsYouGo(weeklyBudget: 500), serviceID: "claude"), [],
            "a budget is measured on this Mac's spend"
        )
    }

    func testASpendLimitListsEarlierThisMonthBeforeOutside() {
        let share = Fixture.limitShare(
            window: month,
            chats: [Fixture.chatShare(id: "chat-a", points: 50, cost: 1_000, lastAt: now)],
            outside: 7,
            earlier: EarlierLocalShare(points: 5, cost: 100)
        )
        XCTAssertEqual(
            LimitsRules.tailRows(of: share, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), serviceID: "claude"),
            [
                LimitsRow(
                    id: "earlier", title: "Earlier this month", subtitle: "This Mac, not split by chat",
                    share: "≈ 5.0 %", dollars: "$100"
                ),
                LimitsRow(
                    id: "outside", title: "Outside this Mac",
                    subtitle: "claude.ai, the desktop app or another machine",
                    share: "≈ 7.0 %", dollars: ""
                ),
            ],
            "a spend limit's Outside is dollars over the limit, not whole half hours"
        )
    }

    func testOnlyASpendLimitFootnotesTheRowsDollars() {
        XCTAssertEqual(
            LimitsCopy.rowsFootnote(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)),
            "API-list prices; your organisation's rate may differ"
        )
        XCTAssertNil(LimitsCopy.rowsFootnote(mode: .subscription), "the price card says it")
        XCTAssertNil(LimitsCopy.rowsFootnote(mode: .payAsYouGo(weeklyBudget: nil)), "the dollars are the bill")
    }
}
