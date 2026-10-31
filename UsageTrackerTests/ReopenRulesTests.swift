import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1, Reopen (owner 2026-10-30): a reopen with no window on
/// screen (a click on an Omelette notification, a double click on the app in Finder) opens the
/// island, never the Dashboard, and keeps AppKit and SwiftUI from their own reopen work; with
/// a window on screen the reopen is left as it was.
final class ReopenRulesTests: XCTestCase {
    func testAReopenWithNoVisibleWindowOpensTheIsland() {
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false), .openIsland)
    }

    func testOpeningTheIslandKeepsAppKitFromBringingTheDashboardForward() {
        XCTAssertFalse(ReopenRules.Action.openIsland.appKitHandlesReopen)
    }

    func testAReopenWithTheDashboardOnScreenIsLeftAsItWas() {
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: true), .leaveAlone)
        XCTAssertTrue(ReopenRules.Action.leaveAlone.appKitHandlesReopen)
    }

    /// With a Dock icon up, the reopen is a click on it while the Dashboard is in the Dock or
    /// the app is hidden: AppKit and SwiftUI bring the window back, the island stays closed.
    func testAReopenWithADockIconAndNoVisibleWindowLeavesTheWindowToAppKit() {
        let action = ReopenRules.action(hasVisibleWindows: false, hasDockIcon: true)
        XCTAssertEqual(action, .leaveAlone)
        XCTAssertTrue(action.appKitHandlesReopen)
    }

    func testAReopenWithADockIconAndAWindowOnScreenIsLeftAsItWas() {
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: true, hasDockIcon: true), .leaveAlone)
    }

    func testAReopenWithNoDockIconAndNoVisibleWindowStillOpensTheIsland() {
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false, hasDockIcon: false), .openIsland)
    }
}
