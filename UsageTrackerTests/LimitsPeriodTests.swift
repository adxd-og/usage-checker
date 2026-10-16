import XCTest
@testable import Omelette

/// The period picker: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The
/// tab, item 1 ("the current window and the past ones inside the 31-day horizon, newest
/// first") and § Accounts without percent windows, Periods ("Pay as you go uses rolling
/// 7-day blocks (the last 7 days, then 7–14 days ago, …) inside the 31-day turn horizon;
/// Spend limit uses calendar months, current month only").
final class LimitsPeriodTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(3_600), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    /// Claude on the API, $412 in the last 7 days.
    private var api: ServiceSnapshot { Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 412) }

    /// The week that ended five days ago, as its readings named it.
    private var lastWeek: LimitPastWindow {
        let end = now.addingTimeInterval(-5 * day)
        return LimitPastWindow(start: end.addingTimeInterval(-7 * day), end: end, resets: end...end)
    }

    private var weekBefore: LimitPastWindow {
        let end = now.addingTimeInterval(-12 * day)
        return LimitPastWindow(start: end.addingTimeInterval(-7 * day), end: end, resets: end...end)
    }

    private func past(_ window: LimitPastWindow) -> LimitsPeriod { .past(window) }

    private func request(_ service: ServiceSnapshot, _ period: LimitsPeriod, budget: Double = 0) -> LimitShareRequest? {
        LimitsRules.request(for: service, kind: .weekly, period: period, weeklyBudgetUSD: budget, now: now, calendar: utc)
    }

    func testASubscriptionOffersItsCurrentWindowThenThePastOnesNewestFirst() {
        XCTAssertEqual(
            LimitsRules.periods(mode: .subscription, pastWindows: [lastWeek, weekBefore]),
            [.current, past(lastWeek), past(weekBefore)]
        )
    }

    func testPayAsYouGoOffersTheThreeEarlierWeeksInsideTheTurnHorizon() {
        XCTAssertEqual(LimitsRules.earlierWeeks, 3, "21–28 days ago is the last block wholly inside 31 days")
        XCTAssertEqual(
            LimitsRules.periods(mode: .payAsYouGo(weeklyBudget: 500), pastWindows: [lastWeek]),
            [.current, .weeksAgo(1), .weeksAgo(2), .weeksAgo(3)]
        )
    }

    func testASpendLimitOrAnAccountWithNoModeOffersTheCurrentPeriodAlone() {
        XCTAssertEqual(
            LimitsRules.periods(mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240), pastWindows: [lastWeek]),
            [.current], "the turn horizon cannot cover a past month"
        )
        XCTAssertEqual(LimitsRules.periods(mode: nil, pastWindows: []), [.current])
    }

    func testThePickerShowsOnlyWithSomethingBesidesTheCurrentPeriod() {
        XCTAssertFalse(LimitsRules.canPickPeriod([.current]))
        XCTAssertTrue(LimitsRules.canPickPeriod([.current, .weeksAgo(1)]))
    }

    func testAPeriodNoLongerOfferedFallsBackToTheCurrentOne() {
        let offered = LimitsRules.periods(mode: .subscription, pastWindows: [lastWeek])
        XCTAssertEqual(LimitsRules.selectedPeriod(past(lastWeek), offered: offered), past(lastWeek))
        XCTAssertEqual(LimitsRules.selectedPeriod(past(weekBefore), offered: offered), .current, "it left the horizon")
        XCTAssertEqual(LimitsRules.selectedPeriod(.weeksAgo(2), offered: offered), .current, "not a subscription's period")
    }

    func testTheCurrentPeriodLoadsWhatTheCurrentWindowLoads() {
        XCTAssertEqual(
            request(claudeMax, .current),
            LimitShareRules.request(for: claudeMax, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
    }

    func testAPastWindowLoadsWithNoLivePercent() {
        XCTAssertEqual(
            request(claudeMax, past(lastWeek)),
            LimitShareRequest(
                mode: .subscription, period: lastWeek.window, bucketID: "seven_day", livePercent: nil,
                resets: lastWeek.resets
            ),
            "its readings are the ones that named its reset; the live bucket is another window's"
        )
    }

    func testAnEarlierWeekIsTheSevenDaysBeforeTheLastSeven() {
        XCTAssertEqual(
            request(api, .weeksAgo(1), budget: 500),
            LimitShareRequest(
                mode: .payAsYouGo(weeklyBudget: 500),
                period: LimitWindow(start: now.addingTimeInterval(-14 * day), end: now.addingTimeInterval(-7 * day)),
                bucketID: nil, livePercent: nil
            )
        )
    }

    func testAPeriodOfAnotherModeLoadsNothing() {
        XCTAssertNil(request(claudeMax, .weeksAgo(1)))
        XCTAssertNil(request(api, past(lastWeek)))
        XCTAssertNil(request(api, .weeksAgo(0)))
    }
}
