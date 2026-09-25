import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings: "the same glass sidebar as the dashboard".
/// Metrics from `Settings-General(-Light).dc.html`'s `<nav>`: 196 pt wide, radius 18,
/// padded 16 / 10 / 14, 3 pt between rows, 12 pt lights over 18 pt, a 22 pt app icon
/// beside "Omelette Settings" at 13 pt, padded 0 8 12.
final class SettingsSidebarTests: XCTestCase {
    func testTheSidebarIsTheMockupsWidthAndCorner() {
        XCTAssertEqual(SettingsSidebarRules.width, 196)
        XCTAssertEqual(OMRadius.corner(for: SettingsSidebarRules.corner), .rounded(18))
    }

    func testTheSidebarIsTheDashboardsGlass() {
        XCTAssertEqual(SettingsSidebarRules.surface, DashboardSidebarRules.surface)
        XCTAssertEqual(SettingsSidebarRules.surface, .sidebar)
    }

    /// Session ruling S7: the mockup's 32 pt items, 10 pt in, 10 pt corner.
    func testItemsAreTheSettingsMockupsSize() {
        XCTAssertEqual(SettingsSidebarRules.itemMetrics, .settings)
        XCTAssertEqual(SettingsSidebarRules.itemMetrics.height, 32)
        XCTAssertEqual(SettingsSidebarRules.itemMetrics.horizontalPadding, 10)
        XCTAssertEqual(SettingsSidebarRules.itemMetrics.cornerRadius, 10)
    }

    func testThePaddingAndRowGapAreTheMockups() {
        XCTAssertEqual(SettingsSidebarRules.topPadding, 16)
        XCTAssertEqual(SettingsSidebarRules.horizontalPadding, 10)
        XCTAssertEqual(SettingsSidebarRules.bottomPadding, 14)
        XCTAssertEqual(SettingsSidebarRules.itemSpacing, 3)
    }

    /// The same 30 pt row and the same 16 pt from the panel's corner as the dashboard's,
    /// so `WindowButtonsPlacement` puts the lights inside it.
    func testTheTrafficLightsKeepTheDashboardsRow() {
        XCTAssertEqual(SettingsSidebarRules.windowControlsRowHeight, DashboardSidebarRules.windowControlsRowHeight)
        XCTAssertEqual(SettingsSidebarRules.topPadding, DashboardShellLayout.windowButtonsPadding)
    }

    func testTheAppNameRowIsTheMockups() {
        XCTAssertEqual(SettingsSidebarRules.brandTitle, "Omelette Settings")
        XCTAssertEqual(SettingsSidebarRules.brandIconSize, 22)
        XCTAssertEqual(SettingsSidebarRules.brandSpacing, 9)
        XCTAssertEqual(SettingsSidebarRules.brandFontSize, 13)
        XCTAssertEqual(SettingsSidebarRules.brandHorizontalPadding, 8)
        XCTAssertEqual(SettingsSidebarRules.brandBottomPadding, 12)
    }

    func testVoiceOverFindsTheSidebarByName() {
        XCTAssertEqual(SettingsSidebarRules.accessibilityName, "Settings sections")
    }

    func testKeyboardFocusOnAnItemWearsTheYolkRing() {
        XCTAssertEqual(SettingsSidebarRules.focusRingToken, .focusRing)
    }

    func testAFocusedItemShowsTheRingUnderKeyboardNavigation() {
        XCTAssertTrue(SettingsSidebarRules.focusRingVisible(on: .providers, focusedTab: .providers, keyboardNavigation: true))
    }

    func testFocusAClickLeftBehindDrawsNoRing() {
        XCTAssertFalse(SettingsSidebarRules.focusRingVisible(on: .providers, focusedTab: .providers, keyboardNavigation: false))
    }

    func testOnlyTheFocusedItemWearsTheRing() {
        XCTAssertFalse(SettingsSidebarRules.focusRingVisible(on: .general, focusedTab: .providers, keyboardNavigation: true))
        XCTAssertFalse(SettingsSidebarRules.focusRingVisible(on: .general, focusedTab: nil, keyboardNavigation: true))
    }
}
