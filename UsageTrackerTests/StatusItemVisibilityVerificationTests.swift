import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.7 and D4 through the composition the
/// status bar controller and the Settings page make: the displays as `IslandScreen` readings
/// decide `notchedDisplayAttached`, which with the stored choice decides whether the item is
/// shown. The executor's tests check each piece alone.
final class StatusItemVisibilityVerificationTests: XCTestCase {
    private func shown(_ setting: Bool?, _ screens: [IslandScreen]) -> Bool {
        StatusItemVisibilityRules.isShown(
            setting: setting, notchedDisplayAttached: StatusItemVisibilityRules.notchedDisplayAttached(screens)
        )
    }

    func testTheLidClosedWithAnExternalDisplayOnlyForcesTheItemOnWhateverTheChoice() {
        for setting: Bool? in [nil, false, true] {
            XCTAssertTrue(shown(setting, [ScreenFixture.externalRight]), "\(String(describing: setting))")
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

    func testASafeAreaWithoutMenuBarAreasIsNotANotchSoTheItemIsForcedOn() {
        let unreadable = IslandScreen(
            id: 6, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 872),
            safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        XCTAssertTrue(shown(false, [unreadable]), "no readable notch means no notch click to rely on")
    }

    func testTheSwitchAndTheItemAgreeOnEveryCombination() {
        // The switch reads `isShown`; it moves only when a notched display is attached.
        for attached in [true, false] {
            for setting: Bool? in [nil, false, true] {
                let reads = StatusItemVisibilityRules.isShown(setting: setting, notchedDisplayAttached: attached)
                if !StatusItemVisibilityRules.switchEnabled(notchedDisplayAttached: attached) {
                    XCTAssertTrue(reads, "a disabled switch must read on (attached \(attached), setting \(String(describing: setting)))")
                }
            }
        }
    }
}
