import SwiftUI
import XCTest
@testable import Omelette

/// Session ruling S7 on the liquid-glass spec § Design → Settings ("the same glass
/// sidebar as the dashboard"): Settings opts into its mockup's smaller items
/// (`Settings-General(-Light).dc.html`: 32 pt rows, 10 pt side padding, 10 pt corner),
/// and the dashboard's stay 34 / 12 / 11 and draw exactly as before.
@MainActor
final class OMSidebarPillMetricsTests: XCTestCase {
    func testTheDashboardSizeIsTheOneItemsAlwaysHad() {
        XCTAssertEqual(
            OMSidebarPillMetrics.dashboard,
            OMSidebarPillMetrics(height: 34, horizontalPadding: 12, cornerRadius: 11)
        )
    }

    func testAnItemThatAsksForNoSizeGetsTheDashboards() {
        XCTAssertEqual(OMSidebarPillButtonStyle(isSelected: true).metrics, .dashboard)
    }

    func testSettingsItemsAreTheSettingsMockups() {
        XCTAssertEqual(
            OMSidebarPillMetrics.settings,
            OMSidebarPillMetrics(height: 32, horizontalPadding: 10, cornerRadius: 10)
        )
    }

    /// The pill used to be `OMCornerShape(.navItem)`; at the dashboard's radius the new
    /// shape draws the same path, whole and inset for the 1 px edge.
    func testTheDashboardPillDrawsExactlyTheNavItemShape() {
        let rect = CGRect(x: 0, y: 0, width: 204, height: 34)
        let pill = OMSidebarPillShape(radius: OMSidebarPillMetrics.dashboard.cornerRadius)
        XCTAssertEqual(pill.path(in: rect), OMCornerShape(.navItem).path(in: rect))
        XCTAssertEqual(pill.inset(by: 0.5).path(in: rect), OMCornerShape(.navItem).inset(by: 0.5).path(in: rect))
    }
}
