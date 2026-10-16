import XCTest
@testable import Omelette

/// A share on screen answers the period picked: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 1. A past week's
/// share is never shown as this week's, nor the other way round; a past session can be
/// picked while no session is open; an earlier 7-day block of pay as you go is its own
/// period, and "nothing spent" there answers that block only.
final class LimitsPeriodQueryTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    private var api: ServiceSnapshot { Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 0) }

    private var thisWeek: LimitWindow { LimitWindow(start: now.addingTimeInterval(-5 * day), end: now) }
    private var lastWeek: LimitWindow {
        LimitWindow(start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day))
    }

    /// `window` as the picker offers it: a past window and the reset its readings named.
    private func past(_ window: LimitWindow) -> LimitsPeriod {
        .past(LimitPastWindow(start: window.start, end: window.end, resets: window.end...window.end))
    }

    private func query(_ service: ServiceSnapshot?, kind: BucketKind = .weekly, period: LimitsPeriod) -> LimitsQuery {
        LimitsRules.query(
            serviceID: "claude", service: service, kind: kind, period: period,
            weeklyBudgetUSD: 0, now: now, calendar: utc
        )
    }

    private func page(
        _ service: ServiceSnapshot?, kind: BucketKind = .weekly, period: LimitsPeriod,
        load: DashboardState.LimitShareLoad? = nil, answered: LimitsQuery? = nil
    ) -> LimitsPage {
        LimitsRules.page(
            serviceID: "claude", kind: kind, period: period, service: service, weeklyBudgetUSD: 0,
            load: load, answered: answered, now: now, calendar: utc
        )
    }

    private func shareLoad(_ window: LimitWindow, kind: BucketKind = .weekly, period: LimitsPeriod) -> DashboardState.LimitShareLoad {
        var answered = Fixture.limitLoad(kind: kind, share: Fixture.limitShare(
            window: window,
            chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 1_200, lastAt: window.end)]
        ))
        answered.period = period
        return answered
    }

    func testAPastWeekIsAQueryOfItsOwn() {
        let pastQuery = query(claudeMax, period: past(lastWeek))
        XCTAssertEqual(pastQuery.measure, .window(start: lastWeek.start))
        XCTAssertEqual(pastQuery.period, past(lastWeek))
        XCTAssertNotEqual(pastQuery, query(claudeMax, period: .current))
    }

    func testAPastWeeksShareIsShownWhileThatWeekIsPicked() {
        let pastLoad = shareLoad(lastWeek, period: past(lastWeek))
        XCTAssertEqual(page(claudeMax, period: past(lastWeek), load: pastLoad), .ready(pastLoad))
    }

    func testThisWeeksShareIsNotAPastWeeksNorTheOtherWayRound() {
        XCTAssertEqual(page(claudeMax, period: past(lastWeek), load: shareLoad(thisWeek, period: .current)), .loading)
        XCTAssertEqual(page(claudeMax, period: .current, load: shareLoad(lastWeek, period: past(lastWeek))), .loading)
    }

    func testAPastSessionIsShownWhileNoSessionIsOpen() {
        let idle = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 0, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
        let session = LimitWindow(start: now.addingTimeInterval(-8 * hour), end: now.addingTimeInterval(-3 * hour))
        let sessionLoad = shareLoad(session, kind: .session, period: past(session))
        XCTAssertEqual(page(idle, kind: .session, period: .current), .noOpenWindow(.session))
        XCTAssertEqual(page(idle, kind: .session, period: past(session), load: sessionLoad), .ready(sessionLoad))
    }

    func testAnEarlierWeekOfPayAsYouGoIsNotTheLastSevenDays() {
        let earlier = query(api, period: .weeksAgo(1))
        XCTAssertNotEqual(earlier, query(api, period: .current))
        XCTAssertEqual(page(api, period: .weeksAgo(1), answered: earlier), .noSpend)
        XCTAssertEqual(page(api, period: .weeksAgo(1), answered: query(api, period: .current)), .loading,
                       "the answer on hand is for the last 7 days")
    }

    func testAPublishedLoadAndItsAnswerCarryThePeriodPicked() throws {
        let share = Fixture.limitShare(
            window: lastWeek,
            chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 1_200, lastAt: lastWeek.end)]
        )
        let request = LimitShareRules.request(
            for: LimitPastWindow(start: lastWeek.start, end: lastWeek.end, resets: lastWeek.end...lastWeek.end),
            bucketID: "seven_day"
        )
        let published = LimitsRules.published(
            serviceID: "claude", kind: .weekly, request: request, share: share, period: past(lastWeek)
        )
        let load = try XCTUnwrap(published.load)
        XCTAssertEqual(load.period, past(lastWeek))
        XCTAssertEqual(published.answer.period, past(lastWeek))
        XCTAssertEqual(load.query, published.answer)
        XCTAssertEqual(
            page(claudeMax, period: past(lastWeek), load: load, answered: published.answer), .ready(load),
            "the past week's share is on screen while that week is picked"
        )
    }
}
