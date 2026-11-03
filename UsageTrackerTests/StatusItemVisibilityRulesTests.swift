import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7 (Show in menu bar), § 3.9 (`StatusItemVisibilityRules`)
/// and D4: off by default while a notched display is attached; shown whatever the setting
/// while none is (clamshell, external display only), since the island has no other way in.
final class StatusItemVisibilityRulesTests: XCTestCase {
    func testOnANotchedMacTheItemIsHiddenUntilTheUserShowsIt() {
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, notchedDisplayAttached: true))
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: true, notchedDisplayAttached: true))
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: false, notchedDisplayAttached: true))
    }

    func testWithNoNotchedDisplayTheItemIsShownWhateverTheSetting() {
        for setting: Bool? in [nil, true, false] {
            XCTAssertTrue(
                StatusItemVisibilityRules.isShown(setting: setting, notchedDisplayAttached: false),
                "\(String(describing: setting))"
            )
        }
    }

    func testTheSwitchMovesOnlyWhileANotchedDisplayIsAttached() {
        XCTAssertTrue(StatusItemVisibilityRules.switchEnabled(notchedDisplayAttached: true))
        XCTAssertFalse(StatusItemVisibilityRules.switchEnabled(notchedDisplayAttached: false))
    }

    func testTheCaptionSaysHowToOpenBriocheOrWhyTheItemStays() {
        XCTAssertEqual(
            StatusItemVisibilityRules.caption(notchedDisplayAttached: true),
            "Click the notch to open Brioche."
        )
        XCTAssertEqual(
            StatusItemVisibilityRules.caption(notchedDisplayAttached: false),
            "Always on while no display with a notch is attached."
        )
    }

    func testANotchedDisplayIsAttachedWhenAnyScreenHasANotch() {
        XCTAssertTrue(StatusItemVisibilityRules.notchedDisplayAttached([ScreenFixture.externalRight, ScreenFixture.builtIn]))
        XCTAssertFalse(StatusItemVisibilityRules.notchedDisplayAttached([ScreenFixture.externalRight, ScreenFixture.externalLeft]))
        XCTAssertFalse(StatusItemVisibilityRules.notchedDisplayAttached([]))
    }

    // MARK: - The first launch after an update (whole-branch review of 4.0, ruling R1)

    private func afterUpdate(
        marked: Bool = false, onboarding: Bool = true, setting: Bool? = nil, notch: Bool = true
    ) -> StatusItemVisibilityRules.FirstLaunchAfterUpdate {
        StatusItemVisibilityRules.firstLaunchAfterUpdate(
            alreadyMarked: marked, hasSeenOnboarding: onboarding, setting: setting, notchedDisplayAttached: notch
        )
    }

    func testAnUpdateOnANotchedMacWithNoStoredSettingOpensTheIsland() {
        XCTAssertEqual(afterUpdate(), .openIsland)
    }

    func testOnlyTheFirstLaunchOpensIt() {
        XCTAssertEqual(afterUpdate(marked: true), .nothing)
    }

    /// Marked, not merely skipped: the launch after the tour must not open it either.
    func testANewInstallHasTheTourAndNeverGetsTheOpen() {
        XCTAssertEqual(afterUpdate(onboarding: false), .markOnly)
        XCTAssertEqual(afterUpdate(onboarding: false, notch: false), .markOnly)
    }

    func testAStoredSettingOfEitherKindNeverGetsTheOpen() {
        XCTAssertEqual(afterUpdate(setting: true), .markOnly)
        XCTAssertEqual(afterUpdate(setting: false), .markOnly)
        XCTAssertEqual(afterUpdate(setting: false, notch: false), .markOnly)
    }

    /// The item is still there. Unmarked: the first launch on the Mac's own display still needs it.
    func testWithNoNotchedDisplayNothingHappensAndALaterLaunchDecides() {
        XCTAssertEqual(afterUpdate(notch: false), .nothing)
        XCTAssertEqual(afterUpdate(notch: true), .openIsland)
    }

    func testTheOpenLeavesTheKeyboardWithTheAppInFront() {
        XCTAssertFalse(IslandEntry.ear(displayID: 1).becomesKey, "the launch opens as an ear does, not as a click")
    }
}
