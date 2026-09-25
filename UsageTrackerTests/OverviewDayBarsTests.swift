import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview" ("CLI card with 30-day bars") and § Components,
/// "Chart tooltip" (`Dashboard-Overview(-Light).dc.html`): thirty daily bars ending today,
/// the seven "Last 7 days" counts brighter and today in yolk, scaled to the biggest day,
/// each with a tooltip of its day, dollars, turns and tokens.
final class OverviewDayBarsTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func daily(_ offset: Int, cost: Double, turns: Int = 1, tokens: Int = 100, at date: Date? = nil) -> CLIDailySummary {
        CLIDailySummary(day: date ?? day(offset), totalCost: cost, totalTokens: tokens,
                        tokens: TokenBreakdown(input: tokens), turns: turns, byFamily: [:])
    }

    func testThirtyBarsRunFromTwentyNineDaysAgoToToday() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(bars.count, 30)
        XCTAssertEqual(bars.first?.day, day(-29))
        XCTAssertEqual(bars.last?.day, day(0))
        XCTAssertTrue(bars.allSatisfy { $0.cost == 0 && $0.turns == 0 })
    }

    func testTodayIsYolkAndTheSixDaysBeforeItAreBrighterThanTheRest() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(bars.last?.tone, .today)
        XCTAssertEqual(bars.filter { $0.tone == .lastWeek }.map(\.day), (-6 ... -1).map { day($0) })
        XCTAssertEqual(bars.filter { $0.tone == .older }.count, 23)
        XCTAssertEqual(OverviewCLIRules.token(for: .today), .accent)
        XCTAssertEqual(OverviewCLIRules.token(for: .lastWeek), .barRecent)
        XCTAssertEqual(OverviewCLIRules.token(for: .older), .track)
    }

    func testEachBarCarriesItsDaysDollarsTurnsAndTokens() {
        let bars = OverviewCLIRules.bars(daily: [daily(-3, cost: 412.3, turns: 3_210, tokens: 612_400_000)],
                                         now: now, calendar: calendar)
        XCTAssertEqual(bars[26].day, day(-3))
        XCTAssertEqual(bars[26].cost, 412.3)
        XCTAssertEqual(bars[26].turns, 3_210)
        XCTAssertEqual(bars[26].tokens, 612_400_000)
    }

    func testTheBrightWeekAddsUpToLastSevenDaysAndTheStripToLastThirty() {
        // Tomorrow's row (a clock set back, a future-stamped log) is in neither total.
        let rows = [daily(1, cost: 32), daily(0, cost: 1), daily(-6, cost: 2), daily(-7, cost: 4),
                    daily(-29, cost: 8), daily(-30, cost: 16)]
        let bars = OverviewCLIRules.bars(daily: rows, now: now, calendar: calendar)
        let week = bars.filter { $0.tone != .older }.reduce(0) { $0 + $1.cost }
        let month = bars.reduce(0) { $0 + $1.cost }
        XCTAssertEqual(week, OverviewCLIRules.cost(daily: rows, lastDays: 7, now: now, calendar: calendar))
        XCTAssertEqual(month, OverviewCLIRules.cost(daily: rows, lastDays: 30, now: now, calendar: calendar))
        XCTAssertEqual(week, 3)
        XCTAssertEqual(month, 15)
    }

    func testRowsKeyedInAnotherTimeZoneLandOnTheDayTheyFallInAndAddUp() {
        // Two rows folded at other zones' midnights, both on Friday 4 September here.
        let rows = [daily(0, cost: 1, at: day(-2).addingTimeInterval(3_600)),
                    daily(0, cost: 2, at: day(-2).addingTimeInterval(21 * 3_600))]
        let bars = OverviewCLIRules.bars(daily: rows, now: now, calendar: calendar)
        XCTAssertEqual(bars[27].day, day(-2))
        XCTAssertEqual(bars[27].cost, 3)
        XCTAssertEqual(bars[27].turns, 2)
    }

    func testBarsScaleToTheBiggestDayAndASmallDayStaysVisible() {
        let bars = OverviewCLIRules.bars(daily: [daily(0, cost: 100), daily(-1, cost: 50), daily(-2, cost: 0.01)],
                                         now: now, calendar: calendar)
        let heights = OverviewCLIRules.barHeights(bars, maxHeight: 118)
        XCTAssertEqual(heights[29], 118)
        XCTAssertEqual(heights[28], 59)
        XCTAssertEqual(heights[27], 2)
        XCTAssertEqual(heights[0], 0)
    }

    func testAStripWithNothingInItDrawsNoBars() {
        let bars = OverviewCLIRules.bars(daily: [], now: now, calendar: calendar)
        XCTAssertEqual(OverviewCLIRules.barHeights(bars, maxHeight: 118), Array(repeating: 0, count: 30))
    }

    func testABarsTooltipIsTheDayAndItsFigures() {
        let bars = OverviewCLIRules.bars(daily: [daily(-3, cost: 412.3, turns: 3_210, tokens: 612_400_000)],
                                         now: now, calendar: calendar)
        XCTAssertEqual(OverviewCLIRules.tooltip(for: bars[26], calendar: calendar, locale: SessionFixture.locale),
                       "Thu 3 Sep · $412.30 · 3210 turns · 612.4M tokens")
        XCTAssertEqual(OverviewCLIRules.tooltip(for: bars[25], calendar: calendar, locale: SessionFixture.locale),
                       "Wed 2 Sep · no usage")
    }

    func testTheAxisRunsFromThirtyDaysAgoToToday() {
        XCTAssertEqual(OverviewCopy.axisStart, "30 days ago")
        XCTAssertEqual(OverviewCopy.axisEnd, "Today")
    }
}
