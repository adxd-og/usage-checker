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
}
