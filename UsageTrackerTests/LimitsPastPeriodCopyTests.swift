import XCTest
@testable import Omelette

/// What the cards say about a past period: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 1 (the picker
/// reaches back to past windows and earlier 7-day blocks) and items 2–3 (the price card,
/// the ranked list). A past window is "that" week or session and how full it got, not
/// "so far"; the price card names the period it prices; the current period keeps the
/// words the Limits tab already gives it.
final class LimitsPastPeriodCopyTests: XCTestCase {
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

    /// 25 Aug 12:00 to 1 Sep 12:00.
    private var lastWeek: LimitWindow {
        LimitWindow(start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day))
    }

    /// `window` as the picker offers it: a past window and the reset its readings named.
    private func past(_ window: LimitWindow) -> LimitsPeriod {
        .past(LimitPastWindow(start: window.start, end: window.end, resets: window.end...window.end))
    }

    func testAPastWeeksListSaysThatWeekAndHowFullItGot() {
        let period = past(lastWeek)
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .week, period: period), "What filled that week")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 64.4, period: period), "64 % used")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .week, period: period), "No chats that week")
    }

    func testAPastSessionOrMonthIsThatSessionOrMonth() {
        let period = past(lastWeek)
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .session, period: period), "What filled that session")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .session, period: period), "No chats in that session")
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .month, period: period), "What filled that month")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .month, period: period), "No chats that month")
    }

    func testAnEarlierWeekOfPayAsYouGoNamesItsDaysWhenEmpty() {
        XCTAssertEqual(
            LimitsCopy.noChats(mode: .payAsYouGo(weeklyBudget: nil), span: .week, period: .weeksAgo(2)),
            "No chats 14–21 days ago"
        )
        XCTAssertEqual(
            LimitsCopy.rankedTitle(mode: .payAsYouGo(weeklyBudget: nil), span: .week, period: .weeksAgo(2)),
            "Where the spend went"
        )
        XCTAssertEqual(
            LimitsCopy.rankedTrailing(mode: .payAsYouGo(weeklyBudget: 500), percent: 82.4, period: .weeksAgo(1)),
            "82 % of budget"
        )
    }

    func testThePriceCardOfAPastWeekNamesTheWeek() {
        var load = Fixture.limitLoad(share: Fixture.limitShare(
            window: lastWeek,
            chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 1_200, lastAt: lastWeek.end)],
            price: PercentPrice(dollars: 60, tokens: 100_000_000)
        ))
        load.period = past(lastWeek)
        let text = LimitsCopy.topCard(for: load, now: now, span: .week, calendar: calendar, locale: locale)
        XCTAssertEqual(text.trailing, "Week of 25 Aug")
        XCTAssertEqual(text.value, "1 % ≈ $60")
    }

    func testThePriceCardOfAPastSessionNamesItsHours() {
        let session = LimitWindow(
            start: now.addingTimeInterval(-day - hour - 20 * 60), end: now.addingTimeInterval(-day + 3 * hour + 40 * 60)
        )
        var load = Fixture.limitLoad(kind: .session, share: Fixture.limitShare(window: session))
        load.period = past(session)
        XCTAssertEqual(
            LimitsCopy.topCard(for: load, now: now, span: .session, calendar: calendar, locale: locale).trailing,
            "Sat 10:40–15:40"
        )
    }

    func testAnEarlierWeeksSpendCardNamesItsDays() {
        let block = LimitWindow(start: now.addingTimeInterval(-14 * day), end: now.addingTimeInterval(-7 * day))
        var load = Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: nil), share: Fixture.limitShare(
            window: block, chats: [Fixture.chatShare(id: "chat-a", points: 100, cost: 80, lastAt: block.end)]
        ))
        load.period = .weeksAgo(1)
        let text = LimitsCopy.topCard(for: load, now: now, span: .week, calendar: calendar, locale: locale)
        XCTAssertEqual(text.trailing, "7–14 days ago")
        XCTAssertEqual(text.value, "$80 in 7 days")
    }

    func testTheCurrentPeriodKeepsTheWordsItHad() {
        XCTAssertEqual(LimitsCopy.rankedTitle(mode: .subscription, span: .week, period: .current), "What filled this week")
        XCTAssertEqual(LimitsCopy.rankedTrailing(mode: .subscription, percent: 27, period: .current), "27 % so far")
        XCTAssertEqual(LimitsCopy.noChats(mode: .subscription, span: .week, period: .current), "No chats this week yet")
        let week = LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        let load = Fixture.limitLoad(share: Fixture.limitShare(window: week))
        XCTAssertEqual(
            LimitsCopy.topCard(for: load, now: now, span: .week, calendar: calendar, locale: locale).trailing,
            "since Tue 12:00"
        )
    }
}
