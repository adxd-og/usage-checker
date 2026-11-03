import XCTest
@testable import Omelette

/// Spec 2026-11-03 § Status item, for the tour's last page: wherever a display shows the island the
/// tip says to click it; with none, the menu bar icon, which is always there then.
final class OnboardingCopyTests: XCTestCase {
    func testTheTourSaysToClickTheIslandWhereADisplayShowsIt() {
        XCTAssertEqual(
            OnboardingCopy.openTip(islandDisplayAttached: true),
            "the island at the top of the screen to open Brioche"
        )
        XCTAssertEqual(
            OnboardingCopy.openTip(islandDisplayAttached: StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRight])),
            "the island at the top of the screen to open Brioche",
            "an external display alone shows the island"
        )
    }

    func testWithNoDisplayShowingTheIslandTheTourPointsAtTheMenuBarIcon() {
        XCTAssertEqual(OnboardingCopy.openTip(islandDisplayAttached: false), "the menu bar icon to open Brioche")
    }
}
