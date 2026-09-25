import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview", and Principle 4 (`Dashboard-Overview.dc.html`):
/// the CLI card's title, today's line, and "Last 7 days" / "Last 30 days" as calendar days
/// ending today: the days its bars draw, and the thirty `ActivityCardRule` counts, so
/// History's calendar gives the same figure.
final class OverviewCLICardTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }
    private let us = Locale(identifier: "en_US")

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func daily(_ offset: Int, cost: Double) -> CLIDailySummary {
        CLIDailySummary(day: day(offset), totalCost: cost, totalTokens: 100,
                        tokens: TokenBreakdown(input: 100), turns: 1, byFamily: [:])
    }

    func testTheTitleNamesTheLogAndToday() {
        XCTAssertEqual(OverviewCopy.cliTitle(shortName: "Claude Code CLI"), "Claude Code CLI · today")
        XCTAssertEqual(OverviewCopy.cliTitle(shortName: nil), "CLI · today")
    }

    func testTodaysLineCountsTurnsAndTokens() {
        XCTAssertEqual(OverviewCopy.todayLine(turns: 4_221, tokens: 824_300_000, locale: us), "4,221 turns · 824.3M tokens")
        XCTAssertEqual(OverviewCopy.todayLine(turns: 1, tokens: 950, locale: us), "1 turn · 950 tokens")
        XCTAssertEqual(OverviewCopy.todayLine(turns: 0, tokens: 0, locale: us), "0 turns · 0 tokens")
    }

    func testTheFiguresAreLabelledAsTheMockupLabelsThem() {
        XCTAssertEqual(OverviewCopy.lastSevenDays, "Last 7 days")
        XCTAssertEqual(OverviewCopy.lastThirtyDays, "Last 30 days")
        XCTAssertEqual(OverviewCopy.noCLIUsage, "No CLI usage recorded yet")
    }

    func testTheLastSevenAndThirtyDaysAreCalendarDaysEndingToday() {
        // Tomorrow's row (a clock set back, a future-stamped log) is in neither total.
        let rows = [daily(1, cost: 32), daily(0, cost: 1), daily(-6, cost: 2), daily(-7, cost: 4),
                    daily(-29, cost: 8), daily(-30, cost: 16)]
        XCTAssertEqual(OverviewCLIRules.cost(daily: rows, lastDays: 7, now: now, calendar: calendar), 3)
        XCTAssertEqual(OverviewCLIRules.cost(daily: rows, lastDays: 30, now: now, calendar: calendar), 15)
    }

    func testThirtyDaysStartWhereTheActivityCalendarsThirtyDaysStart() {
        XCTAssertEqual(OverviewCLIRules.cutoff(lastDays: 30, now: now, calendar: calendar),
                       ActivityCardRule.cutoffs(now: now, calendar: calendar).thirty)
        XCTAssertEqual(OverviewCLIRules.cutoff(lastDays: 7, now: now, calendar: calendar), day(-6))
    }
}
