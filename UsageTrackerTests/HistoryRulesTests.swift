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
