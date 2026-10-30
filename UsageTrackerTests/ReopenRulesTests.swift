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
}
