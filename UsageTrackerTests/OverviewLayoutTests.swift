import XCTest
@testable import Omelette

/// `Dashboard-Overview(-Light).dc.html`'s grid: the rings card spans seven of twelve
/// columns and the CLI card five, 20 pt apart; a column too narrow for the rings and their
/// legend stacks the cards. A provider with no cost log has no CLI or Tokens card (spec
/// § Screens, "Overview": the rings card at full width).
final class OverviewLayoutTests: XCTestCase {
    func testAtTheMockupsWidthTheCardsSplitSevenToFive() {
        // 1280 pt window − 2 × 10 inset − 224 sidebar − 30 − 32 gutters = 974 pt.
        XCTAssertEqual(OverviewLayout.columns(width: 974), OverviewLayout.Columns(rings: 556, cli: 398))
    }

    func testTheCardsStayBesideEachOtherWhileTheRingsCardFitsItsRingAndLegend() {
        XCTAssertEqual(OverviewLayout.columns(width: 884), OverviewLayout.Columns(rings: 504, cli: 360))
        XCTAssertNil(OverviewLayout.columns(width: 883))
    }

    func testTheNarrowestWindowStacksTheCards() {
        // An 884 pt window: 640 − 62 = 578 pt of column.
        XCTAssertNil(OverviewLayout.columns(width: 578))
    }

    func testAnUnboundedProposalLaysOutAtTheFallbackWidthNeverNaN() {
        // SwiftUI proposes nil for an ideal size and may propose an infinite width.
        XCTAssertEqual(OverviewLayout.resolvedWidth(nil), 884)
        XCTAssertEqual(OverviewLayout.resolvedWidth(.infinity), 884)
        XCTAssertEqual(OverviewLayout.resolvedWidth(.nan), 884)
        XCTAssertEqual(OverviewLayout.resolvedWidth(974), 974)
        let columns = OverviewLayout.columns(width: .infinity)
        XCTAssertEqual(columns, OverviewLayout.Columns(rings: 504, cli: 360))
        XCTAssertTrue(columns.map { $0.rings.isFinite && $0.cli.isFinite } ?? false)
    }

    func testTheCardsAreTwentyPointsApartAndTheColumnKeepsTheMockupsPadding() {
        XCTAssertEqual(OverviewLayout.spacing, 20)
        // The header keeps 12 pt under itself; 8 more makes the mockup's 20.
        XCTAssertEqual(OverviewLayout.contentTop, 8)
        XCTAssertEqual(OverviewLayout.contentBottom, 32)
    }

    func testOnlyAProviderWithACostLogGetsTheCLICard() {
        XCTAssertTrue(OverviewLayout.showsCLICard(hasBreakdown: true))
        XCTAssertFalse(OverviewLayout.showsCLICard(hasBreakdown: false))
    }

    func testTokensTodayWaitsForTodaysFirstToken() {
        XCTAssertTrue(OverviewLayout.showsTokensCard(hasBreakdown: true, todayTokens: 1))
        XCTAssertFalse(OverviewLayout.showsTokensCard(hasBreakdown: true, todayTokens: 0))
        XCTAssertFalse(OverviewLayout.showsTokensCard(hasBreakdown: false, todayTokens: 5_000))
    }
}
