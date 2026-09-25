import XCTest
@testable import Omelette

/// Independent verification of `OverviewCLIRules` against ruling D7
/// (`docs/superpowers/plans/2026-09-25-3.0-P3-overview.md`): "Last 7 days" / "Last 30
/// days" are calendar days ending today, summed from `cliBreakdown.daily`, and the figure
/// equals the sum of the bars it sits under. Written without reading
/// `OverviewCLICardTests.swift` or `OverviewDayBarsTests.swift`; uses rows before the
/// window, on the boundary, today and a future-dated row, rather than their fixtures.
final class OverviewCLIRulesVerificationTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }

    private func day(_ offsetFromToday: Int) -> Date {
        calendar.date(byAdding: .day, value: offsetFromToday, to: calendar.startOfDay(for: now))!
    }

    private func row(_ offset: Int, cost: Double, turns: Int = 1, tokens: Int = 100) -> CLIDailySummary {
        CLIDailySummary(day: day(offset), totalCost: cost, totalTokens: tokens,
                         tokens: TokenBreakdown(input: tokens), turns: turns, byFamily: [:])
    }

    // MARK: - D7: cutoff is calendar days, boundary inclusive

    func testCutoffOfSevenDaysIsSixCalendarDaysBeforeToday() {
        XCTAssertEqual(OverviewCLIRules.cutoff(lastDays: 7, now: now, calendar: calendar), day(-6))
    }

    func testCutoffOfThirtyDaysIsTwentyNineCalendarDaysBeforeToday() {
        XCTAssertEqual(OverviewCLIRules.cutoff(lastDays: 30, now: now, calendar: calendar), day(-29))
    }

    /// Rows before the window, exactly on the boundary, today, and tomorrow (excluded).
    func testCostSumsRowsFromTheBoundaryThroughTodayAndExcludesTomorrow() {
        let daily = [
            row(-40, cost: 100), // well before the 30-day window
            row(-29, cost: 5),   // exactly the 30-day boundary
            row(-6, cost: 7),    // exactly the 7-day boundary
            row(0, cost: 3),     // today
            row(1, cost: 999),   // tomorrow: a clock set back or a future-stamped log
        ]

        let thirty = OverviewCLIRules.cost(daily: daily, lastDays: 30, now: now, calendar: calendar)
        XCTAssertEqual(thirty, 5 + 7 + 3, accuracy: 0.001,
                        "30-day total must include the boundary row and today, exclude before-window and tomorrow")

        let seven = OverviewCLIRules.cost(daily: daily, lastDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(seven, 7 + 3, accuracy: 0.001,
                        "7-day total must include its own boundary row and today, exclude the 30-day-only row and tomorrow")
    }

    func testCostOfTodayAloneIsOneDaysRows() {
        let daily = [row(-1, cost: 50), row(0, cost: 9)]
        XCTAssertEqual(OverviewCLIRules.cost(daily: daily, lastDays: 1, now: now, calendar: calendar), 9, accuracy: 0.001)
    }

    func testCostIsZeroWithNoRowsInRange() {
        let daily = [row(-40, cost: 100)]
        XCTAssertEqual(OverviewCLIRules.cost(daily: daily, lastDays: 7, now: now, calendar: calendar), 0, accuracy: 0.001)
    }

    // MARK: - Bars: 30 days, oldest first, tomorrow excluded

    func testBarsAreAlwaysThirtyOldestFirstEndingToday() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(bars.count, 30)
        XCTAssertEqual(bars.first?.day, day(-29))
        XCTAssertEqual(bars.last?.day, day(0))
    }

    func testBarsHaveNoSlotForAFutureDatedRow() {
        let daily = [row(1, cost: 500)]
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        XCTAssertTrue(bars.allSatisfy { $0.day <= day(0) }, "no bar represents a day after today")
        XCTAssertEqual(bars.reduce(0) { $0 + $1.cost }, 0, accuracy: 0.001,
                        "the future row must not leak into any of the 30 bars")
    }

    func testBarsMergeTwoRowsOnTheSameCalendarDay() {
        let daily = [row(0, cost: 1.5, turns: 2, tokens: 40), row(0, cost: 2.5, turns: 3, tokens: 60)]
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        let todayBar = bars.last!
        XCTAssertEqual(todayBar.cost, 4.0, accuracy: 0.001)
        XCTAssertEqual(todayBar.turns, 5)
        XCTAssertEqual(todayBar.tokens, 100)
    }

    func testBarsToneMarksTodayLastWeekAndOlderSeparately() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(bars.last?.tone, .today)
        // The six days before today ("this week brighter" alongside today = 7 days total).
        for offset in -6 ... -1 {
            let bar = bars.first { $0.day == day(offset) }
            XCTAssertEqual(bar?.tone, .lastWeek, "day \(offset) should read as part of the brighter last week")
        }
        let older = bars.first { $0.day == day(-7) }
        XCTAssertEqual(older?.tone, .older)
    }

    // MARK: - D7: the figure is the sum of the bars it sits under

    func testLast30DaysFigureEqualsTheSumOfAllThirtyBars() {
        let daily = (0 ..< 30).map { row(-$0, cost: Double($0) + 1) } + [row(1, cost: 12_345)]
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        let barsTotal = bars.reduce(0) { $0 + $1.cost }
        let ruleTotal = OverviewCLIRules.cost(daily: daily, lastDays: 30, now: now, calendar: calendar)
        XCTAssertEqual(barsTotal, ruleTotal, accuracy: 0.001,
                        "D7: the 'Last 30 days' figure must equal the sum of the strip's bars")
    }

    func testLast7DaysFigureEqualsTheSumOfTheBrightBars() {
        let daily = (0 ..< 30).map { row(-$0, cost: Double($0) + 1) }
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        let brightTotal = bars.filter { $0.tone == .today || $0.tone == .lastWeek }.reduce(0) { $0 + $1.cost }
        let ruleTotal = OverviewCLIRules.cost(daily: daily, lastDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(brightTotal, ruleTotal, accuracy: 0.001,
                        "D7: the 'Last 7 days' figure must equal the sum of the seven bright bars")
    }

    // MARK: - Bar heights: minimum for any spend, zero for none, zero strip stays flat

    func testBarHeightsAreAllZeroWhenNoDayHasAnySpend() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(OverviewCLIRules.barHeights(bars, maxHeight: 100), Array(repeating: 0, count: 30))
    }

    func testBarHeightsGiveANonZeroDayAtLeastTheMinimum() {
        // A tiny day dwarfed by a much bigger one: still visible next to it.
        let daily = [row(-1, cost: 1_000), row(0, cost: 0.0001)]
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        let heights = OverviewCLIRules.barHeights(bars, maxHeight: 100)
        XCTAssertEqual(heights.last, OverviewCLIRules.minimumBarHeight)
    }

    func testBarHeightsScaleProportionallyToTheBiggestDay() {
        let daily = [row(-1, cost: 10), row(0, cost: 5)]
        let bars = OverviewCLIRules.bars(daily: daily, now: now, calendar: calendar)
        let heights = OverviewCLIRules.barHeights(bars, maxHeight: 100)
        guard let lastHeight = heights.last else { return XCTFail("expected a height for today's bar") }
        XCTAssertEqual(Double(lastHeight), 50, accuracy: 0.01, "half the biggest day is half the strip's height")
    }

    // MARK: - Tone-to-token mapping and the tooltip's empty-day fallback

    func testToneToTokenMapping() {
        XCTAssertEqual(OverviewCLIRules.token(for: .older), .track)
        XCTAssertEqual(OverviewCLIRules.token(for: .lastWeek), .barRecent)
        XCTAssertEqual(OverviewCLIRules.token(for: .today), .accent)
    }

    func testTooltipSaysNoUsageForAnEmptyDay() {
        let bar = OverviewDayBar(day: day(0), cost: 0, turns: 0, tokens: 0, tone: .today)
        let tooltip = OverviewCLIRules.tooltip(for: bar, calendar: calendar, locale: SessionFixture.locale)
        XCTAssertTrue(tooltip.hasSuffix("no usage"), "got: \(tooltip)")
    }

    func testTooltipIncludesCostTurnsAndTokensForAWorkingDay() {
        let bar = OverviewDayBar(day: day(0), cost: 12.5, turns: 4, tokens: 1500, tone: .today)
        let tooltip = OverviewCLIRules.tooltip(for: bar, calendar: calendar, locale: SessionFixture.locale)
        XCTAssertTrue(tooltip.contains(SessionCopy.cost(12.5)), "got: \(tooltip)")
        XCTAssertTrue(tooltip.contains(SessionCopy.turns(4)), "got: \(tooltip)")
        XCTAssertTrue(tooltip.contains("1.5k"), "got: \(tooltip)")
    }
}
