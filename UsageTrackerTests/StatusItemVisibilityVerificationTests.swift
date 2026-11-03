import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.7 and D4 through the composition the
/// status bar controller and the Settings page make: the displays as `IslandScreen` readings
/// decide `islandDisplayAttached` (spec 2026-11-03: a notch or a virtual one), which with the stored choice decides whether the item is
/// shown. The executor's tests check each piece alone.
final class StatusItemVisibilityVerificationTests: XCTestCase {
    private func shown(_ setting: Bool?, _ screens: [IslandScreen]) -> Bool {
        StatusItemVisibilityRules.isShown(
            setting: setting, islandDisplayAttached: StatusItemVisibilityRules.islandDisplayAttached(screens)
        )
    }

    func testTheLidClosedWithOnlyAnExternalWhoseMenuBarHidesForcesTheItemOnWhateverTheChoice() {
        for setting: Bool? in [nil, false, true] {
            // Spec 2026-11-03: an external that shows its menu bar carries the island; one whose menu bar hides does not.
            XCTAssertTrue(shown(setting, [ScreenFixture.externalRightMenuBarHidden]), "\(String(describing: setting))")
        }
    }

    func testTheBuiltInAloneHidesTheItemByDefaultAndShowsItOnceChosen() {
        XCTAssertFalse(shown(nil, [ScreenFixture.builtIn]))
        XCTAssertFalse(shown(false, [ScreenFixture.builtIn]))
        XCTAssertTrue(shown(true, [ScreenFixture.builtIn]))
    }

    func testPluggingAnExternalDisplayInKeepsTheChoiceBecauseTheNotchedOneIsStillThere() {
        XCTAssertFalse(shown(nil, [ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.externalLeft]))
    }

    func testANotchAtALargerTextModeStillCountsAsNotched() {
        XCTAssertFalse(shown(nil, [ScreenFixture.narrowNotched]))
    }

    func testASafeAreaWithoutMenuBarAreasAndAHiddenMenuBarIsNoIslandSoTheItemIsForcedOn() {
        let unreadable = IslandScreen(
            id: 6, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 904),
            safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        XCTAssertTrue(shown(false, [unreadable]), "no readable notch and no menu bar mean no notch click to rely on")
    }

    func testTheSwitchAndTheItemAgreeOnEveryCombination() {
        // The switch reads `isShown`; it moves only when a notched display is attached.
        for attached in [true, false] {
            for setting: Bool? in [nil, false, true] {
                let reads = StatusItemVisibilityRules.isShown(setting: setting, islandDisplayAttached: attached)
                if !StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: attached) {
                    XCTAssertTrue(reads, "a disabled switch must read on (attached \(attached), setting \(String(describing: setting)))")
                }
            }
        }
    }
}
