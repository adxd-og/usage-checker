import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings (six tabs, in the mockups' sidebar order) and
/// § Packages P7: "Keep `SettingsRoute` deep links working (map old tab ids: agents →
/// integrations, account → providers)".
final class SettingsTabTests: XCTestCase {
    func testTheSidebarListsTheSixTabsInTheMockupsOrder() {
        XCTAssertEqual(
            SettingsTab.allCases,
            [.general, .menuBar, .providers, .notifications, .integrations, .advanced]
        )
        XCTAssertEqual(
            SettingsTab.allCases.map(\.rawValue),
            ["General", "Menu bar", "Providers", "Notifications", "Integrations", "Advanced"]
        )
    }

    func testEveryTabHasTheMockupsGlyph() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.icon),
            ["gearshape", "menubar.rectangle", "rectangle.grid.1x2", "bell", "powerplug", "slider.horizontal.3"]
        )
    }

    func testATabAskedForByItsOwnNameOpensThatTab() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab.route(legacyID: tab.rawValue), tab, tab.rawValue)
        }
    }

    func testThe2xAgentsTabOpensIntegrations() {
        XCTAssertEqual(SettingsTab.route(legacyID: "Agents"), .integrations)
        XCTAssertEqual(SettingsTab.route(legacyID: "agents"), .integrations)
    }

    func testThe2xAccountTabOpensProviders() {
        XCTAssertEqual(SettingsTab.route(legacyID: "Account"), .providers)
        XCTAssertEqual(SettingsTab.route(legacyID: "account"), .providers)
    }

    /// `PopoverView` ("Enable precise status") and `UsageNotifier` (a hooks install that
    /// failed from the banner) park `SettingsRoute.agentsTab`; both want the hooks.
    @MainActor
    func testThePopoverAndTheHooksBannerStillLandWhereTheHooksAre() {
        XCTAssertEqual(SettingsTab.route(legacyID: SettingsRoute.agentsTab), .integrations)
    }

    func testAnUnknownNameOpensGeneral() {
        XCTAssertEqual(SettingsTab.route(legacyID: "Diagnostics"), .general)
        XCTAssertEqual(SettingsTab.route(legacyID: ""), .general)
    }

    func testCaseAndSpaceAroundANameDoNotMatter() {
        XCTAssertEqual(SettingsTab.route(legacyID: "  menu bar "), .menuBar)
        XCTAssertEqual(SettingsTab.route(legacyID: "NOTIFICATIONS"), .notifications)
    }

    func testArrowKeysStepThroughTheTabsAndStopAtTheEnds() {
        XCTAssertEqual(SettingsTab.step(from: .general, by: 1), .menuBar)
        XCTAssertEqual(SettingsTab.step(from: .providers, by: -1), .menuBar)
        XCTAssertEqual(SettingsTab.step(from: .general, by: -1), .general)
        XCTAssertEqual(SettingsTab.step(from: .advanced, by: 1), .advanced)
    }
}
