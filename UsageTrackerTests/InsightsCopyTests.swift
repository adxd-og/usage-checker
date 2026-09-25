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
}
