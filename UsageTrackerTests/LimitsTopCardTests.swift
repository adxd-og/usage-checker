import XCTest
@testable import Omelette

/// The Limits tab's first card per mode: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 2 ("1 % ≈ $62 ·
/// 130 M tokens", "API-list prices, not your bill", "Not enough use yet") and § Accounts
/// without percent windows, the Top card and Cost caption columns ("$412 of $500 budget"
/// or "$412 in 7 days" with a link to the budget setting, Claude only; "$1,240 of $2,000
/// this month"). The mockup's "since Mon 09:00" is the window's start. The budget link is
/// also under "Nothing spent" on Claude: that is when it is wanted most.
final class LimitsTopCardTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    /// The week since Tuesday 1 September 12:00.
    private var week: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }
    private var lastSevenDays: LimitWindow { LimitWindow(start: now.addingTimeInterval(-7 * day), end: now) }
    /// 2026-09-01 00:00 UTC to now.
    private var month: LimitWindow { LimitWindow(start: Date(timeIntervalSince1970: 1_788_220_800), end: now) }

    private func card(_ load: DashboardState.LimitShareLoad) -> LimitsTopCardText {
        LimitsCopy.topCard(for: load, now: now, calendar: calendar, locale: locale)
    }

    func testASubscriptionPricesAPercentInDollarsAndTokens() {
        let share = Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", points: 27, cost: 1_674, lastAt: now)],
            price: PercentPrice(dollars: 62, tokens: 130_000_000)
        )
        XCTAssertEqual(card(Fixture.limitLoad(share: share)), LimitsTopCardText(
            title: "Price of a percent",
            trailing: "since Tue 12:00",
            value: "1 % ≈ $62",
            valueIsFigure: true,
            detail: "≈ 130 M tokens",
            caption: "API-list prices, not your bill",
            link: nil
        ))
    }

    func testBelowOneAttributedPointThereIsNoPriceYet() {
        let share = Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", points: 0.5, cost: 30, lastAt: now)]
        )
        let text = card(Fixture.limitLoad(share: share))
        XCTAssertEqual(text.value, "Not enough use yet")
        XCTAssertFalse(text.valueIsFigure)
        XCTAssertNil(text.detail)
        XCTAssertEqual(text.caption, "API-list prices, not your bill")
    }

    func testAWindowStartsAtTheNearestMinuteOfItsReset() {
        // A reset at 12:59:59 opened this session at 07:59:59: it reads 8:00.
        let session = LimitWindow(start: now.addingTimeInterval(-4 * hour - 1), end: now)
        let text = card(Fixture.limitLoad(kind: .session, share: Fixture.limitShare(window: session)))
        XCTAssertEqual(text.trailing, "since today 8:00")
    }

    func testPayAsYouGoWithABudgetShowsTheSpendAgainstIt() {
        let share = Fixture.limitShare(
            window: lastSevenDays,
            chats: [Fixture.chatShare(id: "chat-a", points: 82.4, cost: 412, lastAt: now)]
        )
        XCTAssertEqual(card(Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: 500), share: share)), LimitsTopCardText(
            title: "Weekly budget",
            trailing: "last 7 days",
            value: "$412 of $500 budget",
            valueIsFigure: true,
            detail: nil,
            caption: nil,
            link: "Change the budget"
        ))
    }

    func testPayAsYouGoWithoutABudgetShowsTheSpendAndOffersOne() {
        let share = Fixture.limitShare(
            window: lastSevenDays,
            chats: [Fixture.chatShare(id: "chat-a", points: 100, cost: 412, lastAt: now)]
        )
        let text = card(Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: nil), share: share))
        XCTAssertEqual(text.title, "Spend")
        XCTAssertEqual(text.value, "$412 in 7 days")
        XCTAssertNil(text.caption, "the dollars are the bill")
        XCTAssertEqual(text.link, "Set a weekly budget")
    }

    func testCodexHasNoBudgetToLinkTo() {
        let share = Fixture.limitShare(
            window: lastSevenDays,
            chats: [Fixture.chatShare(id: "chat-a", points: 100, cost: 80, lastAt: now)]
        )
        XCTAssertNil(card(Fixture.limitLoad(serviceID: "codex", mode: .payAsYouGo(weeklyBudget: nil), share: share)).link)
    }

    func testASpendLimitShowsTheMonthAgainstTheLimit() {
        let share = Fixture.limitShare(
            window: month,
            chats: [Fixture.chatShare(id: "chat-a", points: 50, cost: 1_000, lastAt: now)],
            outside: 12
        )
        let load = Fixture.limitLoad(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), share: share)
        XCTAssertEqual(card(load), LimitsTopCardText(
            title: "Spend limit",
            trailing: "since 1 Sep",
            value: "$1,240 of $2,000 this month",
            valueIsFigure: true,
            detail: nil,
            caption: nil,
            link: nil
        ))
    }

    func testNothingSpentOnClaudeOffersTheBudgetToo() {
        XCTAssertEqual(
            LimitsCopy.messageLink(for: .noSpend, serviceID: "claude"), "Set a weekly budget",
            "with no budget and no spend, the budget is the one thing to do"
        )
        XCTAssertNil(LimitsCopy.messageLink(for: .noSpend, serviceID: "codex"), "Codex has no budget setting")
        XCTAssertNil(LimitsCopy.messageLink(for: .loading, serviceID: "claude"))
        XCTAssertNil(LimitsCopy.messageLink(for: .unsupported, serviceID: "grok"))
    }

    func testTheBudgetLinkOpensTheAdvancedSettings() {
        XCTAssertEqual(LimitsRules.budgetSettingsTab, .advanced)
        XCTAssertEqual(SettingsTab.route(legacyID: LimitsRules.budgetSettingsTab.rawValue), .advanced)
    }
}
