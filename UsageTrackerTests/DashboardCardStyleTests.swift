import SwiftUI
import XCTest
@testable import Omelette

/// Liquid-glass spec § Tokens ("pane glass … dashboard cards", radius 22) and the cards of
/// `Dashboard-Overview(-Light).dc.html`: every dashboard card is pane glass, the content
/// fill with its 1 px border, in the 22 pt dashboard-card corner.
final class DashboardCardStyleTests: XCTestCase {
    func testADashboardCardIsPaneGlassInTheDashboardCardCorner() {
        XCTAssertEqual(DashboardCardRules.surface, .pane)
        XCTAssertEqual(DashboardCardRules.corner, .dashboardCard)
        XCTAssertEqual(OMRadius.corner(for: DashboardCardRules.corner), .rounded(22))
    }

    func testThePaneIsTheMockupsCardFillAndBorderInBothAppearances() {
        let dark = OMGlass.recipe(DashboardCardRules.surface, scheme: .dark)
        let light = OMGlass.recipe(DashboardCardRules.surface, scheme: .light)
        XCTAssertEqual(dark.fill, .white(0.055))
        XCTAssertEqual(dark.border, .white(0.05))
        XCTAssertEqual(light.fill, .white(0.72))
        XCTAssertEqual(light.border, .black(0.05))
    }
}
