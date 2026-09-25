import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Sidebar", § Tokens (the sidebar is chrome glass) and
/// § Packages P2: a floating sidebar inset in the window. Metrics from
/// `Dashboard-Overview(-Light).dc.html`: a 1280 × 840 window with 10 pt of padding, a
/// 224 pt `<nav>` of radius 18 padded 16 / 10 / 14 with 4 pt between its rows.
final class DashboardShellTests: XCTestCase {
    func testTheSidebarFloatsTenPointsInsideTheWindow() {
        XCTAssertEqual(DashboardShellLayout.windowInset, 10)
    }

    func testTheSidebarIsTheMockupsWidthAndCorner() {
        XCTAssertEqual(DashboardSidebarRules.width, 224)
        XCTAssertEqual(OMRadius.corner(for: DashboardSidebarRules.corner), .rounded(18))
    }

    func testTheSidebarIsChromeGlassWithItsOwnLightEdgeNotPaneGlass() {
        // `.sidebar` is chrome in dark, and chrome with the hairline edge in light (Task 0).
        XCTAssertEqual(DashboardSidebarRules.surface, .sidebar)
    }

    func testTheSidebarPaddingAndRowGapAreTheMockups() {
        XCTAssertEqual(DashboardSidebarRules.topPadding, 16)
        XCTAssertEqual(DashboardSidebarRules.horizontalPadding, 10)
        XCTAssertEqual(DashboardSidebarRules.bottomPadding, 14)
        XCTAssertEqual(DashboardSidebarRules.itemSpacing, 4)
    }

    func testTheTrafficLightsKeepTheirRowAboveTheAppName() {
        // 12 pt lights and 18 pt under them.
        XCTAssertEqual(DashboardSidebarRules.windowControlsRowHeight, 30)
    }

    func testTheAppNameRowIsTheMockups() {
        XCTAssertEqual(DashboardSidebarRules.brandTitle, "Omelette")
        XCTAssertEqual(DashboardSidebarRules.brandIconSize, 24)
        XCTAssertEqual(DashboardSidebarRules.brandSpacing, 9)
        XCTAssertEqual(DashboardSidebarRules.brandFontSize, 13.5)
        XCTAssertEqual(DashboardSidebarRules.brandHorizontalPadding, 8)
        XCTAssertEqual(DashboardSidebarRules.brandBottomPadding, 14)
    }

    func testVoiceOverFindsTheSidebarByName() {
        XCTAssertEqual(DashboardSidebarRules.accessibilityName, "Sidebar")
    }

    func testTheWindowOpensAtTheMockupsSize() {
        XCTAssertEqual(DashboardShellLayout.idealWidth, 1280)
        XCTAssertEqual(DashboardShellLayout.idealHeight, 840)
    }

    func testTheDetailColumnIsNeverNarrowerThanIn27() {
        // 2.7's floor: an 820 pt window with its sidebar at the 180 pt default.
        let detailAtFloor = DashboardShellLayout.minWidth - DashboardShellLayout.windowInset
            - DashboardSidebarRules.width - DashboardShellLayout.windowInset
        XCTAssertEqual(detailAtFloor, 820 - 180)
        XCTAssertEqual(DashboardShellLayout.minWidth, 884)
        XCTAssertEqual(DashboardShellLayout.minHeight, 560)
    }

    func testKeyboardFocusOnAnItemWearsTheYolkRing() {
        XCTAssertEqual(DashboardSidebarRules.focusRingToken, .focusRing)
    }
}
