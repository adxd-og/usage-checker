import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Links", and § Screens, "Overview": "History ›" opens
/// History as the user left it; "Tokens by day ›" opens it on the Chart view's tokens chart. Following
/// a link writes the keys the dashboard window and History read; a provider with no cost
/// log carries History's link on its first card, rings or burn rate.
final class OverviewLinkTests: XCTestCase {
    func testTheLinksAreTitledAsTheMockupWritesThem() {
        XCTAssertEqual(OverviewLink.history.title, "History")
        XCTAssertEqual(OverviewLink.tokensByDay.title, "Tokens by day")
    }

    func testBothLinksOpenHistory() {
        for link in OverviewLink.allCases {
            XCTAssertEqual(DashboardTab.route(storedValue: link.tab.rawValue), .history)
        }
    }

    func testTokensByDayOpensTheTokensChartAndHistoryKeepsTheUsersChart() {
        XCTAssertNil(OverviewLink.history.chartMode)
        XCTAssertEqual(OverviewLink.tokensByDay.chartMode, .tokens)
        XCTAssertEqual(HistoryChartMode(rawValue: "tokens"), .tokens)
        XCTAssertEqual(OverviewLink.historyChartModeKey, "historyChartMode")
    }

    func testTokensByDayOpensHistoryOnItsChartViewAndHistoryKeepsTheUsersView() {
        // History remembers Chart or Calendar; the tokens chart is only on Chart, so
        // "Tokens by day ›" must switch a Calendar-left History back to Chart.
        XCTAssertNil(OverviewLink.history.viewMode)
        XCTAssertEqual(OverviewLink.tokensByDay.viewMode, .chart)
        XCTAssertEqual(HistoryViewMode(rawValue: "chart"), .chart)
    }

    func testOnlyAProviderWithNoCostLogCarriesHistorysLinkOnItsFirstCard() {
        XCTAssertEqual(OverviewLink.onFirstCard(hasBreakdown: false), .history)
        XCTAssertNil(OverviewLink.onFirstCard(hasBreakdown: true))
    }

    func testAQuotaOnlyProviderWithNoCurrentWindowStillLinksToHistory() {
        // Antigravity signed out: its readings are in History, none is in the snapshot, so
        // the burn-rate card stands in for the rings and carries the link itself.
        let antigravity = Fixture.snapshot(id: "antigravity", plan: nil, buckets: [], state: .notSignedIn)
        XCTAssertTrue(OverviewRingsRules.windows(for: antigravity).isEmpty)
        let hasBreakdown = DashboardState.costSource(for: antigravity.id).hasBreakdown
        XCTAssertFalse(hasBreakdown)
        XCTAssertEqual(OverviewLink.onFirstCard(hasBreakdown: hasBreakdown), .history)
    }
}
