import XCTest
@testable import Omelette

/// "What filled the window": spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 3 ("ranked rows, title, project, '≈ 4.2 %' and its dollars … top 8
/// with 'Show all'"). Project names come from the provider's own decoder. Rows come from the share's ranking and only the rows on screen are formatted:
/// a month can hold thousands of chats. The decoder reads the disk in the app, so every
/// test here hands in a pure one.
final class LimitsRankedRowsTests: XCTestCase {
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

    private var week: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }

    /// Stands in for the provider's decoder: a lookup, no disk.
    private func decoded(_ providerID: String, _ slug: String) -> String {
        ["-Users-tester-Projects-alpha": "alpha", "-Users-tester-Projects-beta": "beta"][slug] ?? slug
    }

    private func rows(_ chats: [ChatShare], serviceID: String = "claude", showsAll: Bool = false) -> LimitsRankedRows {
        LimitsRules.chatRows(
            of: Fixture.limitShare(window: week, chats: chats), serviceID: serviceID, showsAll: showsAll,
            calendar: calendar, locale: locale, projectName: decoded
        )
    }

    func testAChatRowCarriesItsNameProjectShareAndDollars() {
        XCTAssertEqual(
            rows([Fixture.chatShare(id: "chat-a", title: "Ledger review", points: 21.9, cost: 1_358, lastAt: now)]),
            LimitsRankedRows(
                rows: [LimitsRow(id: "chat-a", title: "Ledger review", subtitle: "alpha", share: "≈ 21.9 %", dollars: "$1,358")],
                total: 1
            )
        )
    }

    func testANamelessChatReadsAsItsProjectAndTheDayItRan() {
        XCTAssertEqual(
            rows([Fixture.chatShare(id: "chat-a", points: 1, cost: 62, lastAt: now)]).rows.first?.title,
            "alpha · 6 Sep"
        )
    }

    func testTheProvidersOwnDecoderNamesTheProject() {
        let chat = Fixture.chatShare(
            id: "codex-1", title: "Refactor", project: "%2FUsers%2Ftester%2FProjects%2Fbeta",
            points: 3, cost: 20, lastAt: now
        )
        let named = LimitsRules.chatRows(
            of: Fixture.limitShare(window: week, chats: [chat]), serviceID: "codex", showsAll: false,
            calendar: calendar, locale: locale,
            projectName: { providerID, slug in "\(providerID): \(slug)" }
        )
        XCTAssertEqual(named.rows.first?.subtitle, "codex: %2FUsers%2Ftester%2FProjects%2Fbeta")
    }

    func testTheRowsKeepTheSharesRanking() {
        let ranked = [
            Fixture.chatShare(id: "chat-b", title: "B", points: 4.2, cost: 260, lastAt: now),
            Fixture.chatShare(id: "chat-a", title: "A", points: 1.0, cost: 62, lastAt: now),
            Fixture.chatShare(id: "chat-c", title: "C", points: 0.04, cost: 3, lastAt: now),
        ]
        XCTAssertEqual(rows(ranked).rows.map(\.id), ["chat-b", "chat-a", "chat-c"])
        XCTAssertEqual(rows(ranked).rows.map(\.share), ["≈ 4.2 %", "≈ 1.0 %", "< 0.1 %"])
    }

    func testTwoThousandChatsFormatOnlyTheEightOnScreen() {
        let chats = (0..<2_000).map {
            Fixture.chatShare(
                id: String(format: "chat-%04d", $0), title: "Chat \($0)",
                points: Double(2_000 - $0) / 100, cost: 1, lastAt: now
            )
        }
        let share = Fixture.limitShare(window: week, chats: chats)
        var asked = 0
        let capped = LimitsRules.chatRows(
            of: share, serviceID: "claude", showsAll: false, calendar: calendar, locale: locale,
            projectName: { _, _ in
                asked += 1
                return "alpha"
            }
        )
        XCTAssertEqual(capped.rows.map(\.id), (0..<8).map { String(format: "chat-%04d", $0) })
        XCTAssertEqual(capped.total, 2_000)
        XCTAssertEqual(asked, 8, "only the rows on screen are formatted")
        XCTAssertTrue(LimitsRules.canShowAll(count: capped.total))
        XCTAssertFalse(LimitsRules.canShowAll(count: 8))
        XCTAssertEqual(LimitsCopy.showAll(count: capped.total, expanded: false), "Show all (2,000)")
        XCTAssertEqual(LimitsCopy.showAll(count: capped.total, expanded: true), "Show fewer")

        let all = LimitsRules.chatRows(
            of: share, serviceID: "claude", showsAll: true, calendar: calendar, locale: locale,
            projectName: { _, _ in "alpha" }
        )
        XCTAssertEqual(all.rows.count, 2_000)
        XCTAssertEqual(all.total, 2_000)
    }

    func testTheCardIsTitledForItsWindowOrPeriod() {
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .week), "What filled this week")
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .session), "What filled this session")
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .month), "What filled this month", "Codex Free")
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .payAsYouGo(weeklyBudget: 500), span: .week), "What filled the budget")
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .payAsYouGo(weeklyBudget: nil), span: .week), "Where the spend went")
        XCTAssertEqual(
            LimitsCopy.rankedTitle(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), span: .week),
            "What filled this month's limit"
        )
    }

    func testTheCaptionBesideTheTitleSaysWhatTheSharesAreOf() {
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 27), "27 % so far")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .payAsYouGo(weeklyBudget: 500), percent: 82.4), "82 % of budget")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .payAsYouGo(weeklyBudget: nil), percent: 100), "% of spend in 7 days")
        XCTAssertEqual(
            LimitsCopy.rankedTrailing(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), percent: 62),
            "62 % of limit"
        )
    }

    func testAPeriodWithNoChatsSaysSo() {
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .week), "No chats this week yet")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .session), "No chats in this session yet")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .month), "No chats this month yet")
        XCTAssertEqual(LimitsCopy.noChats(mode: .payAsYouGo(weeklyBudget: nil), span: .week), "No chats in the last 7 days")
        XCTAssertEqual(
            LimitsCopy.noChats(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), span: .week),
            "No chats this month yet"
        )
    }
}
