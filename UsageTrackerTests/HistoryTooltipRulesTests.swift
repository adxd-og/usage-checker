import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Chart tooltip": hovering a day shows its date, cost,
/// turns and tokens (Tokens mode: the split by type, biggest first), beside its bar and
/// inside the plot. Figures from `Dashboard-History-Cost` / `-Tokens`.
final class HistoryTooltipRulesTests: XCTestCase {
    private let calendar = SessionFixture.calendar
    private let locale = SessionFixture.locale
    /// Wednesday 2 September 2026, 00:00 UTC.
    private let wednesday = Date(timeIntervalSince1970: 1_788_307_200)

    private func day(
        _ date: Date? = nil, cost: Double = 1_352.28, tokens: Int = 1_871_300_000,
        turns: Int = 6_889, breakdown: TokenBreakdown = .zero
    ) -> HistoryDay {
        HistoryDay(day: date ?? wednesday, cost: cost, tokens: tokens, turns: turns, breakdown: breakdown)
    }

    func testACostDaySaysItsDateCostTurnsAndTokens() {
        XCTAssertEqual(
            HistoryTooltipRules.text(for: day(), mode: .cost, calendar: calendar, locale: locale),
            HistoryTooltip(title: "Wed, 2 Sep", headline: nil, rows: [
                HistoryTooltipRow(label: "Cost", value: "$1,352.28"),
                HistoryTooltipRow(label: "Turns", value: "6,889"),
                HistoryTooltipRow(label: "Tokens", value: "1871.3M"),
            ])
        )
    }

    func testATokensDaySplitsByTypeBiggestFirst() {
        let split = SessionFixture.tokens(
            input: 216_000, output: 3_400_000, cacheRead: 1_828_100_000, cacheWrite5m: 39_600_000
        )
        let tooltip = HistoryTooltipRules.text(
            for: day(tokens: 1_871_316_000, breakdown: split), mode: .tokens,
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(tooltip.title, "Wed, 2 Sep")
        XCTAssertEqual(tooltip.headline, "1871.3M")
        XCTAssertEqual(tooltip.rows, [
            HistoryTooltipRow(label: "Cache read", value: "1828.1M", token: .tokenCacheRead),
            HistoryTooltipRow(label: "Cache write", value: "39.6M", token: .tokenCacheWrite),
            HistoryTooltipRow(label: "Output", value: "3.4M", token: .tokenOutput),
            HistoryTooltipRow(label: "Input", value: "216.0k", token: .tokenInput),
        ])
    }

    /// Review finding F3: every token row carries its type's colour (session ruling S2);
    /// the cost rows carry none.
    func testTokenRowsCarryTheirTypesColourAndCostRowsNone() {
        let split = SessionFixture.tokens(input: 1, output: 2, cacheRead: 3, cacheWrite5m: 4)
        let tokenRows = HistoryTooltipRules.text(
            for: day(breakdown: split), mode: .tokens, calendar: calendar, locale: locale
        ).rows
        XCTAssertEqual(tokenRows.count, 4)
        for row in tokenRows {
            XCTAssertEqual(row.token, TokenCategory.allCases.first { $0.label == row.label }?.token, row.label)
        }
        let costRows = HistoryTooltipRules.text(for: day(), mode: .cost, calendar: calendar, locale: locale).rows
        XCTAssertTrue(costRows.allSatisfy { $0.token == nil })
    }

    func testATypeWithNoTokensHasNoRow() {
        let tooltip = HistoryTooltipRules.text(
            for: day(breakdown: SessionFixture.tokens(input: 10, cacheRead: 90)), mode: .tokens,
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(tooltip.rows.map(\.label), ["Cache read", "Input"])
    }

    func testEqualTypesKeepTheLegendsOrder() {
        let tooltip = HistoryTooltipRules.text(
            for: day(breakdown: SessionFixture.tokens(input: 100, output: 100)), mode: .tokens,
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(tooltip.rows.map(\.label), ["Input", "Output"])
    }

    func testTheTitleIsTheWeekdayAndTheDayAndCanCarryTheTime() {
        XCTAssertEqual(HistoryCopy.tooltipTitle(wednesday, calendar: calendar, locale: locale), "Wed, 2 Sep")
        XCTAssertEqual(
            HistoryCopy.tooltipTitle(wednesday.addingTimeInterval(14 * 3600 + 300), withTime: true,
                                     calendar: calendar, locale: locale),
            "Wed, 2 Sep · 14:05"
        )
    }

    func testTheBubbleSitsRightOfTheBarWhileItFits() {
        // The mockup: bar centre 424.6, half a bar 27.2 + the 6 pt gap, bubble at 457.8.
        XCTAssertEqual(
            HistoryTooltipRules.leadingX(anchorX: 424.6, clearance: 33.2, width: 176, plotWidth: 870),
            457.8, accuracy: 1e-9
        )
    }

    func testNearTheRightEdgeItFlipsToTheBarsLeft() {
        XCTAssertEqual(
            HistoryTooltipRules.leadingX(anchorX: 815.6, clearance: 33.2, width: 176, plotWidth: 870),
            606.4, accuracy: 1e-9
        )
    }

    func testItNeverStartsLeftOfThePlot() {
        XCTAssertEqual(HistoryTooltipRules.leadingX(anchorX: 50, clearance: 10, width: 176, plotWidth: 200), 0)
    }

    func testThePointerFindsTheDayItIsOver() {
        let days = [day(wednesday), day(wednesday.addingTimeInterval(86_400))]
        XCTAssertEqual(
            HistoryRules.day(containing: wednesday.addingTimeInterval(15 * 3600), in: days, calendar: calendar)?.day,
            wednesday
        )
        XCTAssertNil(HistoryRules.day(containing: wednesday.addingTimeInterval(-3600), in: days, calendar: calendar))
    }
}

/// The quota chart's tooltip (`Dashboard-Quota-History`): the fullest windows at the
/// pointer, fullest first, and the reading the dot rings.
final class HistoryQuotaHoverTests: XCTestCase {
    private let calendar = SessionFixture.calendar
    private let locale = SessionFixture.locale
    /// Thursday 3 September 2026, 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_788_436_800)

    /// Readings as (minutes from noon, percent).
    private func series(_ id: String, _ label: String, _ readings: [(Double, Double)]) -> HistoryQuotaSeries {
        HistoryQuotaSeries(
            bucket: QuotaBucketInfo(id: id, label: label, isCore: true, isLive: true),
            points: readings.map { QuotaPoint(time: noon.addingTimeInterval($0.0 * 60), percent: $0.1) }
        )
    }

    func testTheTooltipListsTheThreeFullestWindowsAtThePointer() {
        let all = [
            series("weekly", "Claude/GPT weekly", [(-5, 21)]),
            series("models", "Claude & GPT models", [(-5, 21)]),
            series("five", "Claude/GPT 5-hour", [(0, 1)]),
            series("gmodels", "Gemini models", [(2, 28)]),
            series("gweekly", "Gemini weekly", [(0, 8)]),
            series("gfive", "Gemini 5-hour", [(1, 29)]),
        ]
        let hover = HistoryTooltipRules.quotaHover(at: noon, series: all, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip, HistoryTooltip(title: "Thu, 3 Sep", headline: nil, rows: [
            HistoryTooltipRow(label: "Gemini 5-hour", value: "29%"),
            HistoryTooltipRow(label: "Gemini models", value: "28%"),
            HistoryTooltipRow(label: "Claude/GPT weekly", value: "21%"),
        ]), "a tie keeps the provider's order")
        XCTAssertEqual(hover?.seriesID, "gfive")
        XCTAssertEqual(hover?.point, QuotaPoint(time: noon.addingTimeInterval(60), percent: 29))
    }

    func testAWindowWithNoReadingNearThePointerIsLeftOut() {
        // A week's tolerance is 1 % of it, about 100 minutes; this reading is 10 hours off.
        let all = [series("a", "A", [(-600, 90)]), series("b", "B", [(0, 10)])]
        let hover = HistoryTooltipRules.quotaHover(at: noon, series: all, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip.rows, [HistoryTooltipRow(label: "B", value: "10%")])
    }

    func testNothingNearThePointerMeansNoTooltip() {
        XCTAssertNil(HistoryTooltipRules.quotaHover(
            at: noon, series: [series("a", "A", [(-600, 90)])], range: .sevenDays,
            calendar: calendar, locale: locale
        ))
    }

    func testADayLongChartNamesTheTimeToo() {
        let hover = HistoryTooltipRules.quotaHover(
            at: noon, series: [series("a", "A", [(0, 50)])], range: .oneDay,
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(hover?.tooltip.title, "Thu, 3 Sep · 12:00")
    }

    func testTheNearestReadingWinsAndTheEarlierWinsATie() {
        let points = [
            QuotaPoint(time: noon.addingTimeInterval(-60), percent: 1),
            QuotaPoint(time: noon.addingTimeInterval(60), percent: 2),
            QuotaPoint(time: noon.addingTimeInterval(300), percent: 3),
        ]
        XCTAssertEqual(HistoryTooltipRules.nearestPoint(in: points, to: noon)?.percent, 1)
        XCTAssertEqual(HistoryTooltipRules.nearestPoint(in: points, to: noon.addingTimeInterval(250))?.percent, 3)
        XCTAssertNil(HistoryTooltipRules.nearestPoint(in: [], to: noon))
    }

    func testTheToleranceIsOnePercentOfTheRange() {
        XCTAssertEqual(HistoryTooltipRules.tolerance(range: .sevenDays), 6_048)
        XCTAssertEqual(HistoryTooltipRules.tolerance(range: .oneDay), 864)
    }
}
