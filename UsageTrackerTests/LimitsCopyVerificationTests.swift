import XCTest
@testable import Omelette

/// How the Limits tab spells its figures and cards, at the edges: limit-analytics spec
/// (2026-10-16) § The tab, items 2 and 3 ("≈ 4.2 %", "< 0.1 %", "1 % ≈ $62 · 130 M tokens",
/// the budget link on Claude only) and § Accounts without percent windows (the Top card and
/// Cost caption columns). Dollars are whole from $10 and carry cents below.
final class LimitsCopyVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    private var sevenDays: LimitWindow { LimitWindow(start: now.addingTimeInterval(-7 * day), end: now) }

    private func card(
        _ mode: LimitMode, serviceID: String = "claude", window: LimitWindow? = nil, cost: Double? = nil,
        price: PercentPrice? = nil
    ) -> LimitsTopCardText {
        let share = Fixture.limitShare(window: window ?? sevenDays, chats: [], price: price, cost: cost)
        return LimitsCopy.topCard(
            for: Fixture.limitLoad(serviceID: serviceID, mode: mode, share: share),
            now: now, calendar: calendar, locale: locale
        )
    }

    // MARK: - Shares

    func testEveryShareUnderATenthReadsLessThanATenthEvenWhereRoundingWouldPrintOne() {
        for points in [0.0, 0.01, 0.04999, 0.05, 0.0949, 0.099, 0.099999, 0.09999999, -1, .nan] {
            XCTAssertEqual(LimitsCopy.share(points), "< 0.1 %", "\(points)")
        }
    }

    func testATenthAndAboveReadsOneDecimal() {
        XCTAssertEqual(LimitsCopy.share(0.1), "≈ 0.1 %")
        XCTAssertEqual(LimitsCopy.share(0.1 - 5e-10), "≈ 0.1 %", "a sum of fractions a hair short of a tenth")
        XCTAssertEqual(LimitsCopy.share(0.14), "≈ 0.1 %")
        XCTAssertEqual(LimitsCopy.share(12.34), "≈ 12.3 %")
        XCTAssertEqual(LimitsCopy.share(100), "≈ 100.0 %")
    }

    func testAWholeShareIsWholePointsWithHalvesRoundingUp() {
        XCTAssertEqual(LimitsCopy.wholeShare(0.5), "≈ 1 %")
        XCTAssertEqual(LimitsCopy.wholeShare(1.5), "≈ 2 %")
        XCTAssertEqual(LimitsCopy.wholeShare(2.49), "≈ 2 %")
        XCTAssertEqual(LimitsCopy.wholeShare(14), "≈ 14 %")
    }

    // MARK: - Dollars

    func testDollarsBelowTenCarryExactlyTwoDecimalPlaces() {
        for amount in [0, 0.004, 0.05, 0.42, 6.2, 9.99, 9.995, 9.9999] {
            let text = LimitsCopy.dollars(amount)
            XCTAssertTrue(text.range(of: #"^\$\d+\.\d\d$"#, options: .regularExpression) != nil, "\(amount) read \(text)")
        }
        XCTAssertEqual(LimitsCopy.dollars(0), "$0.00")
        XCTAssertEqual(LimitsCopy.dollars(0.05), "$0.05")
        XCTAssertEqual(LimitsCopy.dollars(9.99), "$9.99")
    }

    func testDollarsFromTenAreWholeAndGroupedByThousandsWhateverTheRegion() {
        XCTAssertEqual(LimitsCopy.dollars(10), "$10")
        XCTAssertEqual(LimitsCopy.dollars(10.49), "$10")
        XCTAssertEqual(LimitsCopy.dollars(99.5), "$100")
        XCTAssertEqual(LimitsCopy.dollars(1_000_000), "$1,000,000")
        XCTAssertEqual(LimitsCopy.dollars(1_358.4), "$1,358")
    }

    func testTokensReadByUnitFromAThousand() {
        XCTAssertEqual(LimitsCopy.tokens(0), "0")
        XCTAssertEqual(LimitsCopy.tokens(999), "999")
        XCTAssertEqual(LimitsCopy.tokens(1_000), "1.0 k")
        XCTAssertEqual(LimitsCopy.tokens(10_000), "10 k")
        XCTAssertEqual(LimitsCopy.tokens(1_500_000), "1.5 M")
        XCTAssertEqual(LimitsCopy.tokens(12_345_678), "12 M")
    }

    func testATokenCountStepsUpAUnitInsteadOfPrintingAThousandOfTheLowerOne() {
        XCTAssertEqual(LimitsCopy.tokens(999_999), "1.0 M")
        XCTAssertEqual(LimitsCopy.tokens(9_999), "10 k")
        XCTAssertEqual(LimitsCopy.tokens(999_999_999), "1.0 B")
    }

    func testAShareHalfwayBetweenTwoTenthsRoundsAwayFromZeroLikeStatusJSON() {
        XCTAssertEqual(LimitsCopy.share(4.25), "≈ 4.3 %")
    }

    // MARK: - Since

    func testAStartWithinHalfAMinuteOfMidnightIsTheSameTextForAReportedSecond() {
        let midnight = Date(timeIntervalSince1970: 1_788_696_000 - 12 * 3_600)
        let early = midnight.addingTimeInterval(-15)
        XCTAssertEqual(
            LimitsCopy.since(early, now: now, calendar: calendar, locale: locale),
            LimitsCopy.since(midnight, now: now, calendar: calendar, locale: locale)
        )
    }

    func testTheMinuteIsTheNearestOneInTheCard() {
        let eight = now.addingTimeInterval(-4 * 3_600)
        XCTAssertEqual(LimitsCopy.since(eight.addingTimeInterval(29), now: now, calendar: calendar, locale: locale), "since today 8:00")
        XCTAssertEqual(LimitsCopy.since(eight.addingTimeInterval(-29), now: now, calendar: calendar, locale: locale), "since today 8:00")
        XCTAssertEqual(LimitsCopy.since(eight.addingTimeInterval(-31), now: now, calendar: calendar, locale: locale), "since today 7:59")
    }

    func testSinceClimbsHistorysLadderFromTodayToAWeekdayToADate() {
        func since(daysAgo: Double) -> String {
            LimitsCopy.since(now.addingTimeInterval(-daysAgo * day), now: now, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(since(daysAgo: 0.25), "since today 6:00")
        XCTAssertEqual(since(daysAgo: 1), "since Sat 12:00")
        XCTAssertEqual(since(daysAgo: 6), "since Mon 12:00")
        XCTAssertEqual(since(daysAgo: 7), "since 30 Aug")
    }

    // MARK: - The first card

    func testThePriceOfAPercentRoundsLikeEveryOtherDollarFigure() {
        XCTAssertEqual(
            card(.subscription, price: PercentPrice(dollars: 0.05, tokens: 900)).value, "1 % ≈ $0.05"
        )
        XCTAssertEqual(
            card(.subscription, price: PercentPrice(dollars: 62.4, tokens: 130_000_000)).value, "1 % ≈ $62"
        )
        XCTAssertEqual(
            card(.subscription, price: PercentPrice(dollars: 62.4, tokens: 130_000_000)).detail, "≈ 130 M tokens"
        )
    }

    func testOnlyClaudePayAsYouGoOffersTheBudgetLink() {
        XCTAssertEqual(card(.payAsYouGo(weeklyBudget: nil), cost: 412).link, "Set a weekly budget")
        XCTAssertEqual(card(.payAsYouGo(weeklyBudget: 500), cost: 412).link, "Change the budget")
        XCTAssertNil(card(.payAsYouGo(weeklyBudget: nil), serviceID: "codex", cost: 12).link)
        XCTAssertNil(card(.payAsYouGo(weeklyBudget: 500), serviceID: "codex", cost: 12).link, "Codex has no budget setting")
        XCTAssertNil(card(.subscription, price: PercentPrice(dollars: 62, tokens: 1)).link)
        XCTAssertNil(card(.subscription).link)
        XCTAssertNil(card(.spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)).link)
    }

    func testTheBudgetLinkBelongsToClaudeAlone() {
        XCTAssertEqual(LimitsCopy.budgetLink(serviceID: "claude", budget: nil), "Set a weekly budget")
        XCTAssertEqual(LimitsCopy.budgetLink(serviceID: "claude", budget: 1), "Change the budget")
        for other in ["codex", "grok", "antigravity", ""] {
            XCTAssertNil(LimitsCopy.budgetLink(serviceID: other, budget: nil), other)
            XCTAssertNil(LimitsCopy.budgetLink(serviceID: other, budget: 500), other)
        }
    }

    func testOnlyNothingSpentOffersALinkUnderItsSentence() {
        let load = Fixture.limitLoad(share: Fixture.limitShare(window: sevenDays))
        let pages: [LimitsPage] = [
            .unsupported, .nothingToMeasure, .noOpenWindow(.session), .noOpenWindow(.week),
            .noOpenWindow(.month), .loading, .ready(load),
        ]
        for page in pages {
            XCTAssertNil(LimitsCopy.messageLink(for: page, serviceID: "claude"), "\(page)")
        }
        XCTAssertEqual(LimitsCopy.messageLink(for: .noSpend, serviceID: "claude"), "Set a weekly budget")
        XCTAssertNil(LimitsCopy.messageLink(for: .noSpend, serviceID: "codex"))
    }

    func testOnlyASubscriptionCardCarriesTheApiListCaption() {
        XCTAssertEqual(card(.subscription).caption, "API-list prices, not your bill")
        XCTAssertNil(card(.payAsYouGo(weeklyBudget: 500), cost: 412).caption, "the dollars are the bill")
        XCTAssertNil(card(.payAsYouGo(weeklyBudget: nil), cost: 412).caption)
        XCTAssertNil(card(.spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)).caption, "its footnote sits under the rows")
    }

    func testAPayAsYouGoCardShowsItsSpendInTheBudgetsDollars() {
        XCTAssertEqual(card(.payAsYouGo(weeklyBudget: 500), cost: 9.5).value, "$9.50 of $500 budget")
        XCTAssertEqual(card(.payAsYouGo(weeklyBudget: nil), cost: 0.05).value, "$0.05 in 7 days")
        XCTAssertEqual(card(.payAsYouGo(weeklyBudget: nil), cost: 1_240).value, "$1,240 in 7 days")
    }

    func testASpendLimitCardPastItsLimitStillSaysSo() {
        XCTAssertEqual(
            card(.spendLimit(monthlyLimit: 2_000, usedCredits: 2_150.4)).value, "$2,150 of $2,000 this month"
        )
    }

    // MARK: - The ranked card's captions

    func testTheTrailingCaptionIsWholePointsWhatEverTheFraction() {
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 0.4), "0 % so far")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 0.6), "1 % so far")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 100), "100 % so far")
        XCTAssertEqual(
            LimitsCopy.rankedTrailing(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 2_100), percent: 105),
            "105 % of limit"
        )
    }

    func testTheShowAllLabelGroupsThousands() {
        XCTAssertEqual(LimitsCopy.showAll(count: 9, expanded: false), "Show all (9)")
        XCTAssertEqual(LimitsCopy.showAll(count: 1_234, expanded: false), "Show all (1,234)")
        XCTAssertEqual(LimitsCopy.showAll(count: 1_234, expanded: true), "Show fewer")
    }
}
