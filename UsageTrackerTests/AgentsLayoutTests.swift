import XCTest
@testable import Omelette

/// `Dashboard-Agents(-Light).dc.html`: the Agents tab's measurements (liquid-glass spec
/// § Screens, "Agents").
final class AgentsLayoutTests: XCTestCase {
    func testTheSourceAndRangeFiltersSitTwelvePointsApartOnTheTitleRow() {
        XCTAssertEqual(AgentsLayout.headerControlsSpacing, 12)
    }
}
