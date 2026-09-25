import XCTest
@testable import Omelette

/// Every string on the Insights tab (liquid-glass spec § Screens, "Insights";
/// `Dashboard-Insights(-Light).dc.html`). Locales and calendars are pinned.
final class InsightsCopyTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func summary(
        weekOverWeek: WeekOverWeek = .empty,
        dailyAverage: InsightsDailyAverage = InsightsDailyAverage(average: nil, activeDays: 0),
        biggestDay: InsightsDayCost? = nil,
        mostUsedModelToday: InsightsModelCost? = nil,
        daysAtLimit: QuotaDaysAtCapacity = QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7),
        quota: QuotaInsights = .empty
    ) -> InsightsSummary {
        InsightsSummary(
            weekOverWeek: weekOverWeek,
            dailyAverage: dailyAverage,
            biggestDay: biggestDay,
            mostUsedModelToday: mostUsedModelToday,
            daysAtLimit: daysAtLimit,
            quota: quota
        )
    }

    private func text(
        _ figure: InsightsFigure,
        _ summary: InsightsSummary,
        buckets: [QuotaBucketInfo] = []
    ) -> InsightsFigureText {
        InsightsCopy.text(for: figure, summary: summary, quotaBuckets: buckets, calendar: utc, locale: us)
    }

    // MARK: - Days at limit

    /// The mockup's card: title, `[n] of 7`, and the caption naming the threshold.
    func testDaysAtLimitReadsAsTheMockupsNOfSeven() {
        XCTAssertEqual(InsightsCopy.daysAtLimitTitle, "Days at limit, 7 days")
        XCTAssertEqual(InsightsCopy.daysAtLimit(0), "0 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimit(1), "1 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimit(3), "3 of 7")
        XCTAssertEqual(InsightsCopy.daysAtLimitCaption, "days the peak reached 95%")
    }

    func testAWeekWithoutAReadingHasNoDaysAtLimitToShow() {
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)), "—"
        )
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 0, observed: 4, span: 7)), "0 of 7"
        )
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 2, observed: 5, span: 7)), "2 of 7"
        )
    }

    // MARK: - Dollars

    /// The mockup's "$2,727.56": grouped, as the popover's cost tile prints dollars.
    func testDollarsAreThePopoversFormat() {
        XCTAssertEqual(InsightsCopy.money(2_727.56, locale: us), "$2,727.56")
        XCTAssertEqual(InsightsCopy.money(0.98, locale: us), "$0.98")
        XCTAssertEqual(InsightsCopy.money(1_352.28, locale: us), OMCostTile.money(1_352.28, locale: us))
    }

    // MARK: - Figures

    func testAnEmptySummaryShowsNoValueExceptThisWeeksDollars() {
        for figure in InsightsFigure.allCases where figure != .weekOverWeek {
            XCTAssertEqual(text(figure, .empty).value, "—", "\(figure)")
        }
        XCTAssertEqual(text(.weekOverWeek, .empty).value, "$0.00")
    }

    func testDaysAtLimitThroughTheFigureRule() {
        let s = summary(daysAtLimit: QuotaDaysAtCapacity(atCapacity: 3, observed: 6, span: 7))

        XCTAssertEqual(
            text(.daysAtLimit, s),
            InsightsFigureText(title: "Days at limit, 7 days", value: "3 of 7", delta: nil, caption: "days the peak reached 95%")
        )
    }

    func testTheQuotaFiguresSayWhatTheyMeasure() {
        let quota = QuotaInsights(
            daysAtCapacity: 1, daysObserved: 9, averageDailyPeak: 72.4, busiestDay: nil,
            todayPeak: 55, averageDailyConsumption: 250, busiestHour: 14
        )
        let s = summary(quota: quota)

        XCTAssertEqual(
            text(.averageDailyPeak, s),
            InsightsFigureText(title: "Average daily peak", value: "72%", delta: nil, caption: "55% so far today")
        )
        XCTAssertEqual(
            text(.quotaPerDay, s),
            InsightsFigureText(title: "Quota used per day", value: "250%", delta: nil, caption: "of a window, resets counted")
        )
        XCTAssertEqual(
            InsightsCopy.text(for: .busiestHour, summary: s, quotaBuckets: [], calendar: utc, locale: gb),
            InsightsFigureText(title: "Busiest hour", value: "14:00", delta: nil, caption: "when the quota climbs most")
        )
    }

    /// Through the user's own clock format: "14:00" is the wrong answer on a machine that
    /// shows 2 PM everywhere else.
    func testAnHourIsPrintedOnTheUsersClock() {
        XCTAssertEqual(InsightsCopy.hour(9, calendar: utc, locale: gb), "09:00")
        XCTAssertEqual(InsightsCopy.hour(14, calendar: utc, locale: gb), "14:00")
    }

    /// Spec § Screens: "most-used model today". The dollars are today's, so the title says so.
    func testTheMostUsedModelIsTitledToday() {
        let s = summary(mostUsedModelToday: InsightsModelCost(model: "Opus 5", cost: 308.95))

        XCTAssertEqual(
            text(.mostUsedModelToday, s),
            InsightsFigureText(title: "Most-used model today", value: "Opus 5", delta: nil, caption: "$308.95")
        )
    }

    // MARK: - This week vs last

    func testThisWeekVsLastReadsAsTheMockup() {
        let s = summary(weekOverWeek: WeekOverWeek(thisWeek: 2_727.56, lastWeek: 2_199.10))

        XCTAssertEqual(
            text(.weekOverWeek, s),
            InsightsFigureText(title: "This week vs last", value: "$2,727.56", delta: "↑ 24%", caption: "Last week $2,199.10")
        )
    }

    func testTheDeltaPointsTheWayTheSpendMoved() {
        XCTAssertEqual(InsightsCopy.weekDelta(WeekOverWeek(thisWeek: 50, lastWeek: 100)), "↓ 50%")
        // Under half a percent either way is no direction at all.
        XCTAssertEqual(InsightsCopy.weekDelta(WeekOverWeek(thisWeek: 100.2, lastWeek: 100)), "0%")
        // A change on a week without spend is no percentage.
        XCTAssertNil(InsightsCopy.weekDelta(WeekOverWeek(thisWeek: 10, lastWeek: 0)))
    }

    // MARK: - Daily average, 30 days

    func testTheDailyAverageReadsAsTheMockup() {
        let s = summary(dailyAverage: InsightsDailyAverage(average: 291.76, activeDays: 29))

        XCTAssertEqual(
            text(.dailyAverage, s),
            InsightsFigureText(title: "Daily average, 30 days", value: "$291.76", delta: nil, caption: "29 active days")
        )
    }

    func testOneActiveDayIsSingular() {
        XCTAssertEqual(InsightsCopy.activeDays(1), "1 active day")
        XCTAssertEqual(InsightsCopy.activeDays(0), "0 active days")
    }

    // MARK: - Dates

    func testADayReadsLikeTheMockup() {
        // 2026-09-02 00:00 UTC, and 21:00 UTC on the 1st, which is the 2nd at UTC+3.
        let sep2 = Date(timeIntervalSince1970: 1_788_307_200)
        let lateSep1 = Date(timeIntervalSince1970: 1_788_296_400)
        var plus3 = utc
        plus3.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!

        XCTAssertEqual(InsightsCopy.day(sep2, calendar: utc), "2 Sep 2026")
        XCTAssertEqual(InsightsCopy.day(lateSep1, calendar: plus3), "2 Sep 2026")
        XCTAssertEqual(InsightsCopy.day(lateSep1, calendar: utc), "1 Sep 2026")
    }

    func testBiggestDayAndBusiestDayCarryTheSameDate() {
        let sep2 = Date(timeIntervalSince1970: 1_788_307_200)
        let quota = QuotaInsights(
            daysAtCapacity: 1, daysObserved: 1, averageDailyPeak: 97,
            busiestDay: DailyPeak(day: sep2, peak: 97, peakBucketID: "gemini_pro"),
            todayPeak: nil, averageDailyConsumption: nil, busiestHour: nil
        )
        let s = summary(biggestDay: InsightsDayCost(day: sep2, cost: 1_352.28), quota: quota)
        let buckets = [QuotaBucketInfo(id: "gemini_pro", label: "Gemini Pro", isCore: true, isLive: true)]

        XCTAssertEqual(
            text(.biggestDay, s),
            InsightsFigureText(title: "Biggest day", value: "$1,352.28", delta: nil, caption: "2 Sep 2026")
        )
        XCTAssertEqual(
            text(.busiestQuotaDay, s, buckets: buckets),
            InsightsFigureText(title: "Busiest day", value: "97%", delta: nil, caption: "2 Sep 2026 · Gemini Pro")
        )
    }

    // MARK: - Session window

    func testTheSessionWindowReadsAsTheMockup() {
        XCTAssertEqual(InsightsCopy.sessionWindowTitle, "Current session window")
        // 2026-09-06 10:30 UTC.
        XCTAssertEqual(
            InsightsCopy.since(Date(timeIntervalSince1970: 1_788_690_600), calendar: utc, locale: gb),
            "since 10:30"
        )
        XCTAssertEqual(InsightsCopy.byProject, "By project")
    }

    func testTurnsAreGroupedAndCounted() {
        XCTAssertEqual(InsightsCopy.turns(1_742, locale: us), "1,742 turns")
        XCTAssertEqual(InsightsCopy.turns(1, locale: us), "1 turn")
        XCTAssertEqual(InsightsCopy.turns(0, locale: us), "0 turns")
    }

    /// A window with no CLI turns names the provider's own tools: Codex's empty window
    /// is not about "Claude Code" or "the Claude apps".
    func testTheEmptyWindowNamesTheProvidersOwnTools() {
        XCTAssertEqual(
            InsightsCopy.emptySession(providerID: "claude"),
            "No Claude Code activity in this window. Whatever the session limit is showing came from somewhere else — the Claude apps, or another machine on this account."
        )
        XCTAssertEqual(
            InsightsCopy.emptySession(providerID: "codex"),
            "No Codex activity in this window. Whatever the session limit is showing came from somewhere else — another Codex client, or another machine on this account."
        )
        XCTAssertEqual(
            InsightsCopy.emptySession(providerID: "grok"),
            "No activity from the CLI in this window. Whatever the session limit is showing came from somewhere else — another app, or another machine on this account."
        )
    }
}
