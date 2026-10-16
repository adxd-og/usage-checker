import XCTest
@testable import Omelette

/// What one chat's entry in `status.json` says of each share: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data ("percent
/// points of the current windows, one decimal") and § Accounts without percent windows
/// (`budgetShare`, "percent of the budget or limit, one decimal"). The shares are cut by
/// the Limits rule itself.
final class PublishedShareFieldsTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let minute: TimeInterval = 60

    /// C ran two days ago. A ($2) and B ($1) ran at the start of the session window, and
    /// B ($1) again ten minutes ago.
    private var turnLog: TurnCostLog {
        TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-c", cost: 3),
            Fixture.turnCost(at: now.addingTimeInterval(-235 * minute), chat: "chat-a", cost: 2),
            Fixture.turnCost(at: now.addingTimeInterval(-230 * minute), chat: "chat-b", cost: 1),
            Fixture.turnCost(at: now.addingTimeInterval(-10 * minute), chat: "chat-b", cost: 1),
        ])
    }

    /// The session window, now − 4 h to now. The first half hour reaches 5 %, which A and
    /// B share 2 : 1. Then 4 more points land in B's last half hour. A has 3.33, B 5.67.
    private var session: LimitShare {
        let window = LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now)
        return LimitShareRules.share(window: window, series: [
            LimitReading(time: window.start.addingTimeInterval(20 * minute), percent: 5),
            LimitReading(time: now, percent: 9),
        ], log: turnLog)
    }

    /// The week, now − 5 d to now:
    /// - its first hour reaches 30 % from outside this Mac;
    /// - C's half hour two days ago adds 5 points;
    /// - B's last half hour adds 5 more.
    ///
    /// A ran in a half hour that moved nothing.
    private var week: LimitShare {
        let window = LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        return LimitShareRules.share(window: window, series: [
            LimitReading(time: window.start.addingTimeInterval(60 * minute), percent: 30),
            LimitReading(time: now.addingTimeInterval(-2 * day + 20 * minute), percent: 35),
            LimitReading(time: now, percent: 40),
        ], log: turnLog)
    }

    func testEachChatCarriesItsPointsOfEachWindowToOneDecimal() {
        let fields = PublishedShareRules.fields([.session: session, .week: week])

        XCTAssertEqual(fields["chat-a"]?.sessionShare, 3.3)
        XCTAssertEqual(fields["chat-b"]?.sessionShare, 5.7)
        XCTAssertEqual(fields["chat-b"]?.weekShare, 5)
        XCTAssertEqual(fields["chat-c"]?.weekShare, 5)
    }

    func testAChatThatRanInAWindowButMovedNothingCarriesZero() {
        let fields = PublishedShareRules.fields([.session: session, .week: week])

        XCTAssertEqual(fields["chat-a"]?.weekShare, 0)
    }

    func testAChatThatDidNotRunInAWindowCarriesNoShareOfIt() {
        let fields = PublishedShareRules.fields([.session: session, .week: week])

        XCTAssertEqual(Set(fields.keys), ["chat-a", "chat-b", "chat-c"])
        XCTAssertNil(fields["chat-c"]?.sessionShare, "C ran two days ago, outside the session window")
        XCTAssertNil(fields["chat-a"]?.budgetShare, "a subscription has no budget share")
    }

    func testABudgetShareIsTheChatsDollarsAsAPercentOfTheBudget() {
        let budget = LimitShareRules.spendShare(
            period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now),
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-d", cost: 25),
                Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-e", cost: 12.34),
            ]),
            denominator: .budget(500)
        )

        XCTAssertEqual(PublishedShareRules.fields([.budget: budget]), [
            "chat-d": ChatShareFields(budgetShare: 5),
            "chat-e": ChatShareFields(budgetShare: 2.5),
        ])
    }

    func testPointsAreRoundedToTheNearestTenth() {
        XCTAssertEqual(PublishedShareRules.oneDecimal(10.0 / 3), 3.3)
        XCTAssertEqual(PublishedShareRules.oneDecimal(17.0 / 3), 5.7)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.04), 0)
        XCTAssertEqual(PublishedShareRules.oneDecimal(99.96), 100)
    }
}
