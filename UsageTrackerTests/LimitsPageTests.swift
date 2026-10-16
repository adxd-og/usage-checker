import XCTest
@testable import Omelette

/// Which page the Limits tab shows: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab ("Grok and Antigravity
/// get an empty state: …") and § Accounts without percent windows (the three modes). A
/// share is shown only when it answered the query the live snapshot and settings ask now:
/// a share of last week, of another window kind or provider, or against another budget is
/// still loading. "Nothing spent" needs the dashboard's answer to that same query.
final class LimitsPageTests: XCTestCase {
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

    /// Claude on the API, nothing in the last 7 days.
    private var api: ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 0)
    }

    /// `claudeMax`'s week: since Tuesday 1 September 12:00.
    private var weekShare: LimitShare {
        Fixture.limitShare(
            window: LimitWindow(start: now.addingTimeInterval(-5 * day), end: now),
            chats: [Fixture.chatShare(id: "chat-a", points: 40, cost: 2_480, lastAt: now)]
        )
    }

    private var lastSevenDays: LimitWindow { LimitWindow(start: now.addingTimeInterval(-7 * day), end: now) }

    private func page(
        _ service: ServiceSnapshot?,
        serviceID: String = "claude",
        kind: BucketKind = .weekly,
        budget: Double = 0,
        load: DashboardState.LimitShareLoad? = nil,
        answered: LimitsQuery? = nil
    ) -> LimitsPage {
        LimitsRules.page(
            serviceID: serviceID, kind: kind, service: service, weeklyBudgetUSD: budget,
            load: load, answered: answered, now: now, calendar: utc
        )
    }

    private func query(_ service: ServiceSnapshot?, serviceID: String = "claude", budget: Double = 0) -> LimitsQuery {
        LimitsRules.query(
            serviceID: serviceID, service: service, kind: .weekly, weeklyBudgetUSD: budget, now: now, calendar: utc
        )
    }

    func testGrokAndAntigravityGetTheEmptyStateThatSaysWhy() {
        let grok = Fixture.snapshot(id: "grok", buckets: [
            Fixture.bucket(id: "grok_weekly", percent: 3, resetsAt: now.addingTimeInterval(day), kind: .weekly),
        ])
        XCTAssertEqual(page(grok, serviceID: "grok"), .unsupported)
        XCTAssertEqual(page(nil, serviceID: "antigravity"), .unsupported)
        XCTAssertEqual(
            LimitsCopy.message(for: .unsupported, providerName: "Grok"),
            "Limit analytics needs a chat-level cost log. Claude and Codex have one."
        )
    }

    func testAnAccountWithNothingToMeasureSaysSo() {
        let signedOut = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn)
        XCTAssertEqual(page(signedOut), .nothingToMeasure)
        XCTAssertEqual(page(nil), .nothingToMeasure, "not polled yet")
        XCTAssertEqual(
            LimitsCopy.message(for: .nothingToMeasure, providerName: "Claude"),
            "Claude has reported no limit to measure yet."
        )
    }

    func testAWindowThatHasNotOpenedSaysSo() {
        let idle = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 0, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
        XCTAssertEqual(page(idle, kind: .session), .noOpenWindow(.session), "no reset time: no session window yet")
        XCTAssertEqual(
            LimitsCopy.message(for: .noOpenWindow(.session), providerName: "Claude"),
            "No session window is open right now."
        )
        XCTAssertEqual(
            LimitsCopy.message(for: .noOpenWindow(.week), providerName: "Claude"),
            "No weekly window is open right now."
        )
        XCTAssertEqual(
            LimitsCopy.message(for: .noOpenWindow(.month), providerName: "Codex"),
            "No monthly window is open right now."
        )
    }

    func testCodexFreesThirtyDayWindowIsAMonthNotAWeek() {
        // Codex gives every window over a day the kind `.weekly`; the free plan's is 30 days.
        let monthly = Fixture.bucket(id: "codex_session", label: "Monthly", percent: 4,
                                     resetsAt: now.addingTimeInterval(10 * day), kind: .weekly,
                                     windowLength: 43_200 * 60)
        let codexFree = Fixture.snapshot(id: "codex", plan: "Free", buckets: [monthly])
        XCTAssertEqual(LimitsRules.span(of: .weekly, in: codexFree), .month)
        XCTAssertEqual(LimitsRules.span(of: .weekly, in: claudeMax), .week)
        XCTAssertEqual(LimitsRules.span(of: .session, in: claudeMax), .session)
        XCTAssertEqual(LimitsRules.span(of: .weekly, in: nil), .week, "with no window to read, the kind decides")
    }

    func testTheShareThatAnsweredThisQueryIsShown() {
        let load = Fixture.limitLoad(share: weekShare)
        XCTAssertEqual(page(claudeMax, load: load), .ready(load))
        XCTAssertNil(LimitsCopy.message(for: .ready(load), providerName: "Claude"), "a page with cards has no sentence")
    }

    func testAShareCutForAnotherWindowKindOrProviderIsStillLoading() {
        XCTAssertEqual(page(claudeMax, load: Fixture.limitLoad(kind: .session, share: weekShare)), .loading)
        XCTAssertEqual(page(claudeMax, load: Fixture.limitLoad(serviceID: "codex", share: weekShare)), .loading)
        XCTAssertEqual(LimitsCopy.message(for: .loading, providerName: "Claude"), "Loading…")
    }

    func testAShareFromThePreviousWeekIsNotThisWeeks() {
        // The snapshot has moved on to the week since Tuesday; the share on hand is the one before.
        let lastWeek = Fixture.limitShare(
            window: LimitWindow(start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day)),
            chats: [Fixture.chatShare(id: "chat-a", points: 70, cost: 4_340, lastAt: now.addingTimeInterval(-6 * day))]
        )
        XCTAssertEqual(page(claudeMax, load: Fixture.limitLoad(share: lastWeek)), .loading)
    }

    func testAShareMeasuredAgainstAnOldBudgetIsNotCurrent() {
        let share = Fixture.limitShare(
            window: lastSevenDays,
            chats: [Fixture.chatShare(id: "chat-a", points: 82.4, cost: 412, lastAt: now)]
        )
        let load = Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: 500), share: share)
        XCTAssertEqual(page(api, budget: 500, load: load), .ready(load))
        XCTAssertEqual(page(api, budget: 1_000, load: load), .loading, "82.4 % of $500 is not a share of $1,000")
    }

    func testPayAsYouGoWithNothingSpentSaysSoOnceTheLoadHasAnsweredIt() {
        XCTAssertEqual(page(api), .loading, "the load has not answered yet")
        XCTAssertEqual(page(api, answered: query(api)), .noSpend)
        XCTAssertEqual(LimitsCopy.message(for: .noSpend, providerName: "Claude"), "Nothing spent in the last 7 days.")
    }

    func testAnAnswerForAnotherQueryIsNeverNothingSpent() {
        XCTAssertEqual(page(api, answered: query(api, budget: 500)), .loading,
                       "the answer on hand was for the $500 budget set before")
        XCTAssertEqual(page(api, answered: query(api, serviceID: "codex")), .loading)
    }

    func testASubscriptionWithoutItsShareIsLoadingNeverNothingSpent() {
        XCTAssertEqual(page(claudeMax, answered: query(claudeMax)), .loading)
    }

    func testTheTabLoadsOnlyOnceTheProvidersCostLogIsIn() {
        let claudeWeek = query(claudeMax)
        XCTAssertFalse(LimitsRules.loads(LimitsLoadKey(query: claudeWeek, ingestedAt: nil)))
        XCTAssertTrue(LimitsRules.loads(LimitsLoadKey(query: claudeWeek, ingestedAt: now)))
        XCTAssertTrue(LimitsRules.loads(LimitsLoadKey(query: query(nil, serviceID: "codex"), ingestedAt: now)))
        XCTAssertFalse(LimitsRules.loads(LimitsLoadKey(query: query(nil, serviceID: "grok"), ingestedAt: now)))
    }
}
