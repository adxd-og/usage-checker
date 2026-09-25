import XCTest
@testable import Omelette

/// `Dashboard-Agents(-Light).dc.html`: the Agents tab's measurements (liquid-glass spec
/// § Screens, "Agents").
final class AgentsLayoutTests: XCTestCase {
    func testTheSourceAndRangeFiltersSitTwelvePointsApartOnTheTitleRow() {
        XCTAssertEqual(AgentsLayout.headerControlsSpacing, 12)
    }

    // MARK: Column

    func testTheCardsSitTwentyPointsApart() {
        XCTAssertEqual(AgentsLayout.cardSpacing, 20)
    }

    func testTheFirstCardSitsTwentyPointsUnderTheTitleRow() {
        XCTAssertEqual(AgentsLayout.headerGap, 8, "20 pt in the mockup, of which DashboardHeader draws 12 below itself")
    }

    func testTheColumnEndsThirtyTwoPointsAboveTheWindowEdge() {
        XCTAssertEqual(AgentsLayout.columnBottom, 32)
    }

    // MARK: Cards and the stats row

    func testACardIsPaddedTwentyPointsTopAndBottomAndTwentyFourAtTheSides() {
        XCTAssertEqual(AgentsLayout.cardVerticalPadding, 20)
        XCTAssertEqual(AgentsLayout.cardHorizontalPadding, 24)
    }

    func testTheStatsColumnsAreTwentyFourPointsApart() {
        XCTAssertEqual(AgentsLayout.statColumnGap, 24)
    }

    func testAStatIsA12Point5LabelOverA26PointFigure() {
        XCTAssertEqual(AgentsLayout.statLabelSize, 12.5)
        XCTAssertEqual(AgentsLayout.statValueSize, 26)
        XCTAssertEqual(AgentsLayout.statValueTracking, -0.5)
        XCTAssertEqual(AgentsLayout.statLabelValueSpacing, 3)
    }

    // MARK: Live card

    func testTheLiveHeaderIsA15PointTitleBesideA12Point5Count() {
        XCTAssertEqual(AgentsLayout.liveTitleSize, 15)
        XCTAssertEqual(AgentsLayout.liveCountSize, 12.5)
        XCTAssertEqual(AgentsLayout.liveTitleCountSpacing, 10)
    }

    func testTheLiveCardIsPaddedEightPointsAtTheBottomWithSixUnderItsHeader() {
        XCTAssertEqual(AgentsLayout.liveBottomPadding, 8)
        XCTAssertEqual(AgentsLayout.liveHeaderGap, 6)
    }

    func testLiveRowsLineUpWithTheTitleAndKeepTheMockupsFourteenPointPadding() {
        // The row pads 14 pt at the sides and 11 pt above and below at either size; the card adds the rest.
        XCTAssertEqual(AgentsLayout.liveRowsInset, 10)
        XCTAssertEqual(AgentsLayout.liveRowsInset + OMAgentRow.horizontalPadding, AgentsLayout.cardHorizontalPadding)
        XCTAssertEqual(AgentsLayout.liveRowPadding, 14)
        XCTAssertEqual(AgentsLayout.liveRowOuterPadding, 3)
        XCTAssertEqual(AgentsLayout.liveRowOuterPadding + OMAgentRow.verticalPadding, AgentsLayout.liveRowPadding)
    }
}
