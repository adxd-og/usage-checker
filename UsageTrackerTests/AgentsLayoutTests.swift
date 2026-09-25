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
}
