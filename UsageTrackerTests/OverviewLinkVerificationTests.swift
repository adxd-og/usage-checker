import XCTest
@testable import Omelette

/// Independent verification of `OverviewLink` against ruling D13
/// (`docs/superpowers/plans/2026-09-25-3.0-P3-overview.md`): "History ›" writes only the
/// tab; "Tokens by day ›" writes `historyChartMode = tokens` first, then the tab; a
/// provider with no cost log gets "History ›" on its first card. Written without reading
/// `OverviewLinkTests.swift`.
final class OverviewLinkVerificationTests: XCTestCase {
    func testHistoryLinkTargetsHistoryAndDoesNotTouchTheChartMode() {
        XCTAssertEqual(OverviewLink.history.tab, .history)
        XCTAssertNil(OverviewLink.history.chartMode, "\"History ›\" must not switch the chart under the user")
    }

    func testTokensByDayLinkTargetsHistoryOnTheTokensChart() {
        XCTAssertEqual(OverviewLink.tokensByDay.tab, .history)
        XCTAssertEqual(OverviewLink.tokensByDay.chartMode, .tokens)
    }

    func testLinkTitlesMatchTheMockupsCopy() {
        XCTAssertEqual(OverviewLink.history.title, "History")
        XCTAssertEqual(OverviewLink.tokensByDay.title, "Tokens by day")
    }

    /// D13: "A provider with no cost log shows 'History ›' on its first card."
    func testOnFirstCardIsHistoryOnlyWhenTheProviderHasNoCostLog() {
        XCTAssertNil(OverviewLink.onFirstCard(hasBreakdown: true),
                     "a provider with a CLI card must not carry a second, redundant History link")
        XCTAssertEqual(OverviewLink.onFirstCard(hasBreakdown: false), .history,
                        "the quota-only case (Antigravity, Gemini): the rings or burn card carries the only link")
    }

    /// S6: "P3 writes `@AppStorage(\"historyChartMode\")` = `tokens`" — the key this enum
    /// writes under must be the exact key `SessionHistoryView` reads its chart mode from
    /// (spec Facts: `SessionHistoryView.swift:11 · @AppStorage("historyChartMode")`).
    func testHistoryChartModeKeyMatchesTheLiteralHistoryReadsFrom() {
        XCTAssertEqual(OverviewLink.historyChartModeKey, "historyChartMode")
    }

    /// The window that follows a link must land on the same `UserDefaults` key
    /// `DashboardWindow` persists its own tab selection under.
    func testEveryLinksTabRoutesThroughTheSharedDashboardTabStorageKey() {
        XCTAssertEqual(DashboardTab.storageKey, "dashboardTab")
        for link in OverviewLink.allCases {
            XCTAssertEqual(link.tab, .history, "P3 has exactly one destination screen")
        }
    }
}
