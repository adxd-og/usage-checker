import XCTest
@testable import Omelette

/// Independent verification of `HistoryTooltipRules` against liquid-glass spec §
/// Components "Chart tooltip" and review finding F3 (Tokens-mode rows carry their
/// category's dot). Own fixtures.
final class HistoryTooltipRulesVerificationTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let locale = Locale(identifier: "en_US")

    /// 2026-09-02 10:00 UTC, a Wednesday (Sept 6 is a Sunday).
    private let wednesday = Date(timeIntervalSince1970: 1_788_343_200)

    private func makeDay(cost: Double, turns: Int, breakdown: TokenBreakdown) -> HistoryDay {
        HistoryDay(day: wednesday, cost: cost, tokens: breakdown.total, turns: turns, breakdown: breakdown)
    }

    // MARK: - Cost mode: no dots, three rows

    func testCostModeShowsCostTurnsTokensWithNoDots() {
        let breakdown = TokenBreakdown(input: 100, output: 3_400_000, cacheRead: 1_828_100_000, cacheWrite5m: 39_600_000)
        let day = makeDay(cost: 1_352.28, turns: 6_889, breakdown: breakdown)
        let tooltip = HistoryTooltipRules.text(for: day, mode: .cost, calendar: calendar, locale: locale)

        XCTAssertNil(tooltip.headline, "cost mode has no headline beside the date")
        XCTAssertEqual(tooltip.rows.map(\.label), ["Cost", "Turns", "Tokens"])
        XCTAssertEqual(tooltip.rows[0].value, HistoryCopy.dollars(1_352.28))
        XCTAssertEqual(tooltip.rows[1].value, HistoryCopy.count(6_889))
        XCTAssertEqual(tooltip.rows[2].value, TokenFormat.formatTokens(day.tokens))
        XCTAssertTrue(tooltip.rows.allSatisfy { $0.token == nil }, "cost rows have no dot")
    }

    // MARK: - Tokens mode: F3, each row carries its category's colour

    func testTokensModeOrdersTypesBySizeAndCarriesTheirColourDot() {
        // Mirrors the mockup's Tokens tooltip order: cache read, cache write, output, input.
        let breakdown = TokenBreakdown(input: 216_000, output: 3_400_000, cacheRead: 1_828_100_000, cacheWrite5m: 39_600_000)
        let day = makeDay(cost: 0, turns: 1, breakdown: breakdown)
        let tooltip = HistoryTooltipRules.text(for: day, mode: .tokens, calendar: calendar, locale: locale)

        XCTAssertEqual(tooltip.headline, TokenFormat.formatTokens(day.tokens))
        XCTAssertEqual(tooltip.rows.map(\.label), ["Cache read", "Cache write", "Output", "Input"])
        XCTAssertEqual(tooltip.rows.map(\.token), [.tokenCacheRead, .tokenCacheWrite, .tokenOutput, .tokenInput])
    }

    func testTokensModeOmitsAZeroCategory() {
        let breakdown = TokenBreakdown(input: 500, output: 0, cacheRead: 0, cacheWrite5m: 0)
        let day = makeDay(cost: 0, turns: 1, breakdown: breakdown)
        let tooltip = HistoryTooltipRules.text(for: day, mode: .tokens, calendar: calendar, locale: locale)
        XCTAssertEqual(tooltip.rows.map(\.label), ["Input"])
    }

    func testTokensModeTiesBreakByLegendOrder() {
        // input and output tied at 100; TokenCategory.allCases order is
        // input, output, cacheRead, cacheWrite, so input leads.
        let breakdown = TokenBreakdown(input: 100, output: 100, cacheRead: 0, cacheWrite5m: 0)
        let day = makeDay(cost: 0, turns: 1, breakdown: breakdown)
        let tooltip = HistoryTooltipRules.text(for: day, mode: .tokens, calendar: calendar, locale: locale)
        XCTAssertEqual(tooltip.rows.map(\.label), ["Input", "Output"])
    }

    func testTooltipTitleNamesTheWeekdayAndDay() {
        let title = HistoryCopy.tooltipTitle(wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(title.hasPrefix("Wed,"), "got \(title)")
    }

    // MARK: - leadingX: flips at the plot's right edge

    func testLeadingXSitsRightOfTheBarWhenItFits() {
        let x = HistoryTooltipRules.leadingX(anchorX: 10, clearance: 6, width: 176, plotWidth: 400)
        XCTAssertEqual(x, 16)
    }

    func testLeadingXFlipsToTheBarsLeftNearTheRightEdge() {
        let x = HistoryTooltipRules.leadingX(anchorX: 250, clearance: 6, width: 176, plotWidth: 300)
        XCTAssertEqual(x, 68, "250 - 6 - 176")
    }

    func testLeadingXNeverGoesLeftOfThePlot() {
        let x = HistoryTooltipRules.leadingX(anchorX: 5, clearance: 6, width: 176, plotWidth: 50)
        XCTAssertEqual(x, 0)
    }

    // MARK: - Quota hover: D7

    private func series(_ id: String, _ points: [(Date, Double)]) -> HistoryQuotaSeries {
        HistoryQuotaSeries(
            bucket: QuotaBucketInfo(id: id, label: id, isCore: true, isLive: true),
            points: points.map { QuotaPoint(time: $0.0, percent: $0.1) }
        )
    }

    func testQuotaHoverOrdersFullestFirst() {
        let t = wednesday
        let series = [
            series("a", [(t, 40)]),
            series("b", [(t, 90)]),
            series("c", [(t, 60)]),
        ]
        let hover = HistoryTooltipRules.quotaHover(at: t, series: series, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip.rows.map(\.label), ["b", "c", "a"])
        XCTAssertEqual(hover?.seriesID, "b", "the dot rings the fullest row")
    }

    func testQuotaHoverTiesKeepProviderOrder() {
        let t = wednesday
        let series = [
            series("first", [(t, 70)]),
            series("second", [(t, 70)]),
        ]
        let hover = HistoryTooltipRules.quotaHover(at: t, series: series, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip.rows.map(\.label), ["first", "second"])
    }

    func testQuotaHoverCapsAtThreeRows() {
        let t = wednesday
        let all = (0..<6).map { series("w\($0)", [(t, Double(50 + $0))]) }
        let hover = HistoryTooltipRules.quotaHover(at: t, series: all, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip.rows.count, 3)
        XCTAssertEqual(hover?.tooltip.rows.map(\.label), ["w5", "w4", "w3"], "fullest three")
    }

    func testQuotaHoverExcludesAWindowWithNoReadingWithinOnePercentOfTheRange() {
        let t = wednesday
        let tolerance = HistoryTooltipRules.tolerance(range: .sevenDays)
        let near = series("near", [(t.addingTimeInterval(tolerance * 0.5), 80)])
        let far = series("far", [(t.addingTimeInterval(tolerance * 5), 99)])
        let hover = HistoryTooltipRules.quotaHover(at: t, series: [near, far], range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertEqual(hover?.tooltip.rows.map(\.label), ["near"])
    }

    func testQuotaHoverIsNilWhenNothingIsNear() {
        let t = wednesday
        let tolerance = HistoryTooltipRules.tolerance(range: .sevenDays)
        let far = series("far", [(t.addingTimeInterval(tolerance * 10), 99)])
        let hover = HistoryTooltipRules.quotaHover(at: t, series: [far], range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertNil(hover)
    }

    func testQuotaHoverAddsTimeOnlyForDayLongCharts() {
        let t = wednesday
        let s = [series("w", [(t, 50)])]
        let day = HistoryTooltipRules.quotaHover(at: t, series: s, range: .oneDay, calendar: calendar, locale: locale)
        let week = HistoryTooltipRules.quotaHover(at: t, series: s, range: .sevenDays, calendar: calendar, locale: locale)
        XCTAssertTrue(day?.tooltip.title.contains("·") == true, "24h adds the time: \(day?.tooltip.title ?? "")")
        XCTAssertFalse(week?.tooltip.title.contains("·") == true, "7d does not: \(week?.tooltip.title ?? "")")
    }
}
