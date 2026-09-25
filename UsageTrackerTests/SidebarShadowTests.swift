import XCTest
@testable import Omelette

/// Session ruling S8 on the liquid-glass spec § Components, "Sidebar": the floating
/// sidebar's drop shadows (`OMGlass.sidebarShadows`) are cast outside the pane by one
/// shared modifier, for the dashboard and Settings alike. The numbers are the ones
/// `DashboardSidebar` computed in place.
final class SidebarShadowTests: XCTestCase {
    /// Dark: blur 30 at y 10 → 3 × 15 + 10; blur 10 at y 2 → 3 × 5 + 2.
    func testTheMaskReachesThreeRadiiPastTheWidestDarkShadow() {
        XCTAssertEqual(OMSidebarShadowRules.reach(OMGlass.sidebarShadows(scheme: .dark)), 55)
    }

    /// Light: blur 24 at y 8 → 3 × 12 + 8; blur 8 at y 2 → 3 × 4 + 2.
    func testTheMaskReachesThreeRadiiPastTheWidestLightShadow() {
        XCTAssertEqual(OMSidebarShadowRules.reach(OMGlass.sidebarShadows(scheme: .light)), 44)
    }

    func testNoShadowsReachNothing() {
        XCTAssertEqual(OMSidebarShadowRules.reach([]), 0)
    }

    func testTheCastersSitOnePointInsideTheCutout() {
        XCTAssertEqual(OMSidebarShadowRules.casterInset, 1)
    }
}
