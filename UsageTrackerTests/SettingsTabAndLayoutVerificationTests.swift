import XCTest
@testable import Omelette

/// Independent verification of P7 (liquid-glass redesign spec § Design → Settings,
/// § Packages P7, § Decisions "Settings (2026-09-25)", plan ruling D7/D2). Exercises
/// `SettingsTab.route(legacyID:)`, `SettingsTab.step(from:by:)` and
/// `SettingsWindowLayout` directly, independent of the executor's own
/// `SettingsTabTests` / `SettingsKitTests`.
final class SettingsTabAndLayoutVerificationTests: XCTestCase {

    // MARK: - route(legacyID:)

    /// Spec § Packages P7: "Keep `SettingsRoute` deep links working (map old tab ids:
    /// agents → integrations, account → providers)."
    func testTheThreeNamedLegacyIDsRouteWhereThePlanSaysTheyGo() {
        XCTAssertEqual(SettingsTab.route(legacyID: "Agents"), .integrations)
        XCTAssertEqual(SettingsTab.route(legacyID: "Account"), .providers)
        // A 3.0 tab's own raw value routes to itself.
        XCTAssertEqual(SettingsTab.route(legacyID: "Providers"), .providers)
    }

    func testCaseAndSurroundingWhitespaceAreIgnoredOnEveryPath() {
        XCTAssertEqual(SettingsTab.route(legacyID: "AGENTS"), .integrations)
        XCTAssertEqual(SettingsTab.route(legacyID: "  agents  "), .integrations)
        XCTAssertEqual(SettingsTab.route(legacyID: "\tAccount\n"), .providers)
        XCTAssertEqual(SettingsTab.route(legacyID: "aDvAnCeD"), .advanced)
        XCTAssertEqual(SettingsTab.route(legacyID: "  Menu bar "), .menuBar)
    }

    /// D7 / S14: "2.x ignored an unknown id; the brief sets General" — an id that is
    /// neither a 3.0 tab name nor a retired id (not just empty) also opens General.
    func testAnUnrecognisedIDOpensGeneral() {
        XCTAssertEqual(SettingsTab.route(legacyID: ""), .general)
        XCTAssertEqual(SettingsTab.route(legacyID: "Diagnostics"), .general)
        XCTAssertEqual(SettingsTab.route(legacyID: "agentsx"), .general)
        XCTAssertEqual(SettingsTab.route(legacyID: "   "), .general)
    }

    // MARK: - step(from:by:)

    /// The sidebar order is General, Menu bar, Providers, Notifications, Integrations,
    /// Advanced; arrow keys clamp at both ends rather than wrapping.
    func testStepClampsAtBothEndsAndIgnoresLargeOffsets() {
        XCTAssertEqual(SettingsTab.step(from: .general, by: -1), .general)
        XCTAssertEqual(SettingsTab.step(from: .general, by: -100), .general)
        XCTAssertEqual(SettingsTab.step(from: .advanced, by: 1), .advanced)
        XCTAssertEqual(SettingsTab.step(from: .advanced, by: 100), .advanced)
        XCTAssertEqual(SettingsTab.step(from: .providers, by: 0), .providers)
    }

    func testStepWalksTheFullOrderOneAtATime() {
        let order: [SettingsTab] = [.general, .menuBar, .providers, .notifications, .integrations, .advanced]
        for i in 0..<(order.count - 1) {
            XCTAssertEqual(SettingsTab.step(from: order[i], by: 1), order[i + 1], "\(order[i]) -> next")
            XCTAssertEqual(SettingsTab.step(from: order[i + 1], by: -1), order[i], "\(order[i + 1]) -> previous")
        }
    }

    // MARK: - SettingsWindowLayout

    /// D2: "780 pt wide."
    func testWindowWidthIs780() {
        XCTAssertEqual(SettingsWindowLayout.width, 780)
    }

    /// D2: "Height per tab is the mockup's window: General 600, Menu bar 680, Providers
    /// 560, Notifications 960, Integrations 840, Advanced 810." With no screen height
    /// known, the window uses the mockup's height unclamped.
    func testEveryTabsMockupHeightWithNoKnownScreen() {
        let expected: [SettingsTab: CGFloat] = [
            .general: 600, .menuBar: 680, .providers: 560,
            .notifications: 960, .integrations: 840, .advanced: 810,
        ]
        for (tab, height) in expected {
            XCTAssertEqual(SettingsWindowLayout.height(for: tab, availableHeight: nil), height, tab.rawValue)
        }
    }

    /// D2: "cut to the screen's visible height less 40 pt" — a screen tall enough that
    /// the cut does not bind still gives the mockup's height.
    func testATallScreenDoesNotShrinkTheWindow() {
        XCTAssertEqual(SettingsWindowLayout.height(for: .notifications, availableHeight: 2000), 960)
    }

    /// A screen shorter than the mockup plus margin cuts the window to
    /// `availableHeight - screenMargin`.
    func testAShortScreenCutsTheWindowToItsVisibleHeightLessTheMargin() {
        // Notifications wants 960; a 500 pt screen leaves 460, which is above the floor.
        XCTAssertEqual(SettingsWindowLayout.height(for: .notifications, availableHeight: 500), 460)
    }

    /// D2: "with a 420 pt floor" — however short the screen, height never drops below it.
    func testTheWindowNeverShrinksBelowTheFloorOnAnyTab() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsWindowLayout.height(for: tab, availableHeight: 100), 420, tab.rawValue)
            XCTAssertGreaterThanOrEqual(SettingsWindowLayout.height(for: tab, availableHeight: 0), 420, tab.rawValue)
        }
    }

    /// The floor and the mockup height must never cross: a screen exactly at
    /// `mockupHeight + screenMargin` is the boundary where the cut just starts to bind.
    func testTheBoundaryBetweenTheMockupHeightAndTheCutIsExact() {
        let mockup = SettingsWindowLayout.mockupHeight(.general) // 600
        XCTAssertEqual(
            SettingsWindowLayout.height(for: .general, availableHeight: mockup + SettingsWindowLayout.screenMargin),
            mockup
        )
        XCTAssertEqual(
            SettingsWindowLayout.height(for: .general, availableHeight: mockup + SettingsWindowLayout.screenMargin - 1),
            mockup - 1
        )
    }
}
