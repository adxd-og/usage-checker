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

    func testTheHeaderSitsOnTheMockupsColumnGutters() {
        // The detail column's `padding: 24px 32px 32px 30px` in every dashboard mockup.
        XCTAssertEqual(DashboardShellLayout.columnTop, 24)
        XCTAssertEqual(DashboardShellLayout.columnLeading, 30)
        XCTAssertEqual(DashboardShellLayout.columnTrailing, 32)
    }

    // MARK: Traffic lights (owner's visual check, 2026-09-25)

    /// AppKit's close button on macOS 26 and later: 14 × 14 pt.
    private let closeButton = CGSize(width: 14, height: 14)

    func testTheTrafficLightsSitSixteenPointsInsideTheSidebarsTopCorner() {
        // Dashboard-Overview.dc.html: the <nav> sits 10 pt inside the window and its
        // lights row starts 16 pt below its top edge and 10 + 6 pt in from its left.
        XCTAssertEqual(DashboardShellLayout.windowButtonsPadding, 16)
        // AppKit frames count up from the bottom: an 840 pt window puts the close
        // button's bottom-left corner 26 pt in and 10 + 16 + 14 pt below the top.
        XCTAssertEqual(DashboardShellLayout.windowButtonsOrigin(closeButtonSize: closeButton, contentHeight: 840),
                       CGPoint(x: 26, y: 800))
    }

    func testTheLightsKeepTheirDistanceFromTheTopWhateverTheWindowsHeight() {
        XCTAssertEqual(DashboardShellLayout.windowButtonsOrigin(closeButtonSize: closeButton, contentHeight: 560),
                       CGPoint(x: 26, y: 520))
        XCTAssertEqual(DashboardShellLayout.windowButtonsOrigin(closeButtonSize: CGSize(width: 16, height: 16),
                                                                 contentHeight: 840),
                       CGPoint(x: 26, y: 798))
    }

    func testTheTitleBarStripReachesDownToTheLightsSoEveryPointOfAButtonTakesAClick() {
        // AppKit's strip is 32 pt tall; the part of a button below it is outside the
        // strip's hit-test and clicks fall through to the sidebar.
        XCTAssertEqual(DashboardShellLayout.windowButtonsStripHeight(closeButtonSize: closeButton), 40)
    }

    func testTheAppNameRowStartsBelowTheLights() {
        // 16 pt padding, the 30 pt lights row and the 4 pt gap: the mockups' 50 pt,
        // 20 pt under the bottom of a 14 pt button that sits 16 pt below the same edge.
        XCTAssertEqual(DashboardSidebarRules.appNameRowTop, 50)
        XCTAssertGreaterThan(DashboardSidebarRules.appNameRowTop,
                             DashboardShellLayout.windowButtonsPadding + closeButton.height)
    }
}
