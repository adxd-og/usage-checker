import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "History · Chart": Cost and Tokens are the chart's two
/// units, and the chat list sits under the chart in both instead of being a third mode.
final class HistoryRulesModeTests: XCTestCase {
    func testTheChartOffersCostAndTokensOnly() {
        XCTAssertEqual(HistoryRules.chartModes, [.cost, .tokens])
    }

    func testARememberedSessionsModeReadsAsCost() {
        // 2.x's third mode is still in historyChartMode for anyone who left the tab on it.
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .sessions), .cost)
    }

    func testCostAndTokensStayWhatTheyWere() {
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .cost), .cost)
        XCTAssertEqual(HistoryRules.effectiveMode(stored: .tokens), .tokens)
    }
}

/// Liquid-glass spec § Screens, "History · Chart": the range row is 24h 7d 30d 90d 1y.
/// 5h stays a `TimeRange` for Agents; History shows a day in its place.
final class HistoryRulesRangeTests: XCTestCase {
    func testHistoryOffersTheMockupsFiveRanges() {
        XCTAssertEqual(HistoryRules.ranges, [.oneDay, .sevenDays, .thirtyDays, .ninetyDays, .oneYear])
        XCTAssertEqual(RangePicker.items(for: HistoryRules.ranges).map(\.id), ["24h", "7d", "30d", "90d", "1y"])
    }

    func testAnOfferedRangeStaysWhatItIs() {
        for range in HistoryRules.ranges {
            XCTAssertEqual(HistoryRules.offeredRange(range), range)
        }
    }

    func testFiveHoursSetOnAgentsShowsAsADay() {
        XCTAssertEqual(HistoryRules.offeredRange(.fiveHours), .oneDay)
    }
}
