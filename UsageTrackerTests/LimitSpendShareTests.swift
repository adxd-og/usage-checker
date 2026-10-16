import XCTest
@testable import Omelette

/// Each mode's share denominator outside a subscription: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Accounts without percent
/// windows, the mode table's "A chat's share" and "Outside this Mac" columns.
/// - Pay as you go: chat cost / weekly budget, or else chat cost / the period's local
///   spend.
/// - Spend limit: chat cost / monthly limit, and Outside is the server's used credits
///   minus this Mac's spend, when positive.
/// - Ruling C6: that Outside has no time, so it is carried unbinned. The bins' deltas
///   plus `unbinnedOutside` add up to the total in every mode.
final class LimitSpendShareTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Seven days: 336 bins.
    private var period: LimitWindow { LimitWindow(start: start, end: start.addingTimeInterval(7 * 86_400)) }

    private func spendShare(
        _ turns: [TurnCost], _ denominator: SpendDenominator, outsideDollars: Double = 0
    ) -> LimitShare {
        LimitShareRules.spendShare(
            period: period, log: TurnCostLog(turns: turns), denominator: denominator,
            outsideDollars: outsideDollars
        )
    }

    func testWithABudgetPayAsYouGoMeasuresAChatAgainstTheBudget() {
        XCTAssertEqual(
            LimitShareRules.denominator(for: .payAsYouGo(weeklyBudget: 500), periodSpend: 412),
            .budget(500)
        )
        let share = spendShare([
            Fixture.turnCost(at: at(5), chat: "chat-a", cost: 100),
            Fixture.turnCost(at: at(600), chat: "chat-b", cost: 312),
        ], .budget(500))

        XCTAssertEqual(share.chats.map(\.id), ["chat-b", "chat-a"])
        XCTAssertEqual(share.chats[0].points, 62.4, accuracy: 1e-9)
        XCTAssertEqual(share.chats[1].points, 20, accuracy: 1e-9)
        XCTAssertEqual(share.percent, 82.4, accuracy: 1e-9, "$412 of a $500 budget")
        XCTAssertEqual(share.outside, 0, "the budget is measured on this Mac's spend")
        XCTAssertNil(share.price, "the dollars are the bill: a percent of a budget has no price")
    }

    func testWithoutABudgetPayAsYouGoMeasuresAChatAgainstThePeriodsSpend() {
        XCTAssertEqual(
            LimitShareRules.denominator(for: .payAsYouGo(weeklyBudget: nil), periodSpend: 400),
            .spend(400)
        )
        let share = spendShare([
            Fixture.turnCost(at: at(5), chat: "chat-a", cost: 100),
            Fixture.turnCost(at: at(600), chat: "chat-b", cost: 300),
        ], .spend(400))

        XCTAssertEqual(share.chats.map(\.points), [75, 25], "% of spend")
        XCTAssertEqual(share.percent, 100, accuracy: 1e-9)
    }

    func testWithNothingToMeasureAgainstThereIsNoDenominator() {
        XCTAssertNil(LimitShareRules.denominator(for: .payAsYouGo(weeklyBudget: nil), periodSpend: 0))
        XCTAssertNil(
            LimitShareRules.denominator(for: .subscription, periodSpend: 100),
            "a subscription is measured by its percent, not by dollars"
        )
    }

    func testASpendLimitMeasuresAChatAgainstTheMonthlyLimit() {
        XCTAssertEqual(
            LimitShareRules.denominator(for: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), periodSpend: 1_000),
            .monthlyLimit(2_000)
        )
        let share = spendShare([Fixture.turnCost(at: at(5), chat: "chat-a", cost: 400)], .monthlyLimit(2_000))
        XCTAssertEqual(share.chats.first?.points ?? -1, 20, accuracy: 1e-9)
    }

    func testSpendLimitOutsideIsTheServersCreditsMinusThisMacsSpendWhenPositive() {
        XCTAssertEqual(LimitShareRules.spendLimitOutside(usedCredits: 1_240, localSpend: 1_000), 240)
        XCTAssertEqual(
            LimitShareRules.spendLimitOutside(usedCredits: 1_240, localSpend: 1_300), 0,
            "this Mac's API-list dollars can run ahead of the organisation's rate"
        )
        let share = spendShare(
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1_000)], .monthlyLimit(2_000),
            outsideDollars: 240
        )
        XCTAssertEqual(share.outside, 12, accuracy: 1e-9)
        XCTAssertEqual(share.percent, 62, accuracy: 1e-9, "$1,240 of $2,000")
    }

    func testEachHalfHourOfTheTimelineCarriesItsShareOfTheDenominator() {
        let share = spendShare([
            Fixture.turnCost(at: at(5), chat: "chat-a", cost: 100),
            Fixture.turnCost(at: at(40), chat: "chat-b", cost: 50),
        ], .budget(500))

        XCTAssertEqual(share.bins.count, 336)
        XCTAssertEqual(share.bins[0].delta, 20, accuracy: 1e-9)
        XCTAssertEqual(Array(share.bins[0].chats.keys), ["chat-a"])
        XCTAssertEqual(share.bins[1].delta, 10, accuracy: 1e-9)
        XCTAssertEqual(share.bins[2].delta, 0)
    }

    func testTheTimelineAndTheUnbinnedOutsideAddUpToTheTotalInEveryMode() {
        let spendLimit = spendShare(
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1_000)], .monthlyLimit(2_000),
            outsideDollars: 240
        )
        XCTAssertEqual(
            spendLimit.unbinnedOutside, 12, accuracy: 1e-9,
            "the server reports the month's other spend with no time to bin it by"
        )
        XCTAssertEqual(spendLimit.outside, spendLimit.unbinnedOutside)
        XCTAssertEqual(
            spendLimit.bins.map(\.delta).reduce(0, +) + spendLimit.unbinnedOutside, spendLimit.percent,
            accuracy: 1e-9
        )

        let subscription = LimitShareRules.share(
            window: LimitWindow(start: start, end: at(180)),
            bucketID: "five_hour",
            readings: Fixture.readings(bucketID: "five_hour", points: [
                (at: at(20), percent: 3), (at: at(75), percent: 7),
            ]),
            log: TurnCostLog(turns: [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 2)])
        )
        XCTAssertEqual(subscription.outside, 4)
        XCTAssertEqual(subscription.unbinnedOutside, 0, "a subscription's Outside lives in its bins")
        XCTAssertEqual(
            subscription.bins.map(\.delta).reduce(0, +) + subscription.unbinnedOutside, subscription.percent,
            accuracy: 1e-9
        )
    }
}
