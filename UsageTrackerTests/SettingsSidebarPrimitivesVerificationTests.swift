import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of P7's shared-primitive rulings (plan "Session rulings
/// (2026-09-25)" S7 and S8): `OMSidebarPillMetrics.dashboard` must still equal the
/// dashboard's own pinned constants, `OMSidebarPillShape(radius: 11)` must draw
/// exactly `OMCornerShape(.navItem)`'s path, and `OMSidebarShadowRules.reach` must
/// match the dashboard sidebar's real shadow recipe in both schemes.
final class SettingsSidebarPrimitivesVerificationTests: XCTestCase {

    // MARK: - OMSidebarPillMetrics

    /// S7: "`.dashboard` (34 / 12 / 11) is the default and pinned." Reads the same
    /// constants `OMSidebarPillRules` and `OMRadius.navItem` publish, so a change to
    /// either without updating `.dashboard` fails here.
    func testDashboardMetricsEqualTheMergeBaseConstants() {
        XCTAssertEqual(OMSidebarPillMetrics.dashboard.height, OMSidebarPillRules.height)
        XCTAssertEqual(OMSidebarPillMetrics.dashboard.horizontalPadding, OMSidebarPillRules.horizontalPadding)
        XCTAssertEqual(OMSidebarPillMetrics.dashboard.cornerRadius, OMRadius.navItem)
        XCTAssertEqual(OMSidebarPillMetrics.dashboard, OMSidebarPillMetrics(height: 34, horizontalPadding: 12, cornerRadius: 11))
    }

    /// S7: "`.settings` is 32 / 10 / 10", as mocked (`Settings-General.dc.html`).
    func testSettingsMetricsAreTheMockups() {
        XCTAssertEqual(OMSidebarPillMetrics.settings, OMSidebarPillMetrics(height: 32, horizontalPadding: 10, cornerRadius: 10))
    }

    /// S7: "the dashboard's items unchanged" — `.omSidebarPill(isSelected:)` with no
    /// `metrics` argument still defaults to `.dashboard`.
    func testTheDefaultButtonStyleMetricArgumentIsDashboard() {
        let style = OMSidebarPillButtonStyle(isSelected: true)
        XCTAssertEqual(style.metrics, .dashboard)
    }

    // MARK: - OMSidebarPillShape

    /// The doc comment's claim: "At 11 pt it draws exactly `OMCornerShape(.navItem)`."
    /// Checked at several rectangle sizes, including a non-square one (a sidebar row).
    func testTheShapeAtRadiusElevenDrawsExactlyTheNavItemCorner() {
        let rects = [
            CGRect(x: 0, y: 0, width: 176, height: 34),
            CGRect(x: 0, y: 0, width: 50, height: 50),
            CGRect(x: 3, y: 7, width: 200, height: 32),
        ]
        for rect in rects {
            XCTAssertEqual(
                OMSidebarPillShape(radius: 11).path(in: rect),
                OMCornerShape(.navItem).path(in: rect),
                "rect \(rect)"
            )
        }
    }

    /// An inset shape (as `strokeBorder` applies) must also match: both shapes shrink
    /// their radius by the same inset amount.
    func testTheShapeStaysEqualAfterAMatchingInset() {
        let rect = CGRect(x: 0, y: 0, width: 176, height: 34)
        let insettedPill = OMSidebarPillShape(radius: 11).inset(by: 1.5)
        let insettedCorner = OMCornerShape(.navItem).inset(by: 1.5)
        XCTAssertEqual(insettedPill.path(in: rect), insettedCorner.path(in: rect))
    }

    /// At the Settings radius (10, not 11) the two shapes must differ, so the "exactly"
    /// claim is specific to 11 pt and not an accident of the path formula.
    func testAtTheSettingsRadiusTheShapeDiffersFromTheNavItemCorner() {
        let rect = CGRect(x: 0, y: 0, width: 176, height: 32)
        XCTAssertNotEqual(OMSidebarPillShape(radius: 10).path(in: rect), OMCornerShape(.navItem).path(in: rect))
    }

    // MARK: - OMSidebarShadowRules.reach

    /// Facts / plan brief: "`OMSidebarShadowRules.reach` 55 dark / 44 light", computed
    /// from the real recipe `OMGlass.sidebarShadows` still returns, not a hardcoded
    /// number: `max(3 * blur/2 + |y|)` over both shadow layers.
    func testReachIsFiftyFiveDarkAndFortyFourLight() {
        XCTAssertEqual(OMSidebarShadowRules.reach(OMGlass.sidebarShadows(scheme: .dark)), 55)
        XCTAssertEqual(OMSidebarShadowRules.reach(OMGlass.sidebarShadows(scheme: .light)), 44)
    }

    /// An empty shadow list reaches nothing; a caster inset by 1 pt is the rule's other constant.
    func testReachOfNoShadowsIsZeroAndCasterInsetIsOnePoint() {
        XCTAssertEqual(OMSidebarShadowRules.reach([]), 0)
        XCTAssertEqual(OMSidebarShadowRules.casterInset, 1)
    }
}
