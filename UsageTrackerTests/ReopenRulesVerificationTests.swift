import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.1, Reopen (owner 2026-10-30), written
/// independently of `ReopenRulesTests`: the whole truth table of what `applicationShouldHandleReopen`
/// does, as the pure rule gives it.
final class ReopenRulesVerificationTests: XCTestCase {
    /// What the delegate returns for AppKit's flag. Only a reopen with no window on screen
    /// takes AppKit's own reopen work (SwiftUI's first scene, the Dashboard) away.
    func testTheDelegateAnswerIsFalseExactlyWhenNoWindowIsOnScreen() {
        for hasVisibleWindows in [false, true] {
            let action = ReopenRules.action(hasVisibleWindows: hasVisibleWindows)
            XCTAssertEqual(
                action.appKitHandlesReopen, hasVisibleWindows,
                "hasVisibleWindows \(hasVisibleWindows): AppKit may reopen only when a window is already up"
            )
        }
    }

    func testTheIslandOpensOnlyWhenNothingIsOnScreen() {
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false), .openIsland)
        XCTAssertNotEqual(ReopenRules.action(hasVisibleWindows: true), .openIsland, "a visible Dashboard or Settings is never covered by the island")
    }
}
