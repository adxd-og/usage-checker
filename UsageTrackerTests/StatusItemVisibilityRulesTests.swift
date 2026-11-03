import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7 (Show in menu bar), § 3.9 (`StatusItemVisibilityRules`)
/// and D4, as spec 2026-11-03 § Status item widens them: off by default while a display shows the
/// island — a notch, or the pill on a display without one; shown whatever the setting while none
/// does (every menu bar hidden, or only displays under 1280 pt), since the island has no other way in.
final class StatusItemVisibilityRulesTests: XCTestCase {
    func testWithAnIslandDisplayTheItemIsHiddenUntilTheUserShowsIt() {
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: true))
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: true, islandDisplayAttached: true))
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: false, islandDisplayAttached: true))
    }

    func testWithNoIslandDisplayTheItemIsShownWhateverTheSetting() {
        for setting: Bool? in [nil, true, false] {
            XCTAssertTrue(
                StatusItemVisibilityRules.isShown(setting: setting, islandDisplayAttached: false),
                "\(String(describing: setting))"
            )
        }
    }

    func testTheSwitchMovesOnlyWhileAnIslandDisplayIsAttached() {
        XCTAssertTrue(StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: true))
        XCTAssertFalse(StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: false))
    }

    func testTheCaptionSaysHowToOpenBriocheOrWhyTheItemStays() {
        XCTAssertEqual(
            StatusItemVisibilityRules.caption(islandDisplayAttached: true),
            "Click the island at the top of the screen to open Brioche."
        )
        XCTAssertEqual(
            StatusItemVisibilityRules.caption(islandDisplayAttached: false),
            "Always on while no display shows the island."
        )
    }

    func testAnIslandDisplayIsAttachedWhenAnyScreenCarriesAnIsland() {
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRight, ScreenFixture.builtIn]))
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRight, ScreenFixture.externalLeft]))
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.wide1280]))
        XCTAssertFalse(
            StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRightMenuBarHidden, ScreenFixture.narrow1279])
        )
        XCTAssertFalse(StatusItemVisibilityRules.islandDisplayAttached([]))
    }

    /// The owner's call (spec 2026-11-03): an external display, with the lid open or closed, is no
    /// reason to force the item on any more.
    func testAnExternalDisplayAloneLeavesTheItemToTheSetting() {
        let attached = StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRight])
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: attached))
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: true, islandDisplayAttached: attached))
    }

    func testEveryMenuBarHiddenOrOnlyNarrowDisplaysForceTheItemOn() {
        let attached = StatusItemVisibilityRules.islandDisplayAttached(
            [ScreenFixture.externalRightMenuBarHidden, ScreenFixture.externalLeftMenuBarHidden, ScreenFixture.narrow1279]
        )
        XCTAssertTrue(StatusItemVisibilityRules.isShown(setting: false, islandDisplayAttached: attached))
    }

    // MARK: - The first launch after an update (whole-branch review of 4.0, ruling R1; spec 2026-11-03)

    private func afterUpdate(
        marked: Bool = false, onboarding: Bool = true, setting: Bool? = nil, island: Bool = true
    ) -> StatusItemVisibilityRules.FirstLaunchAfterUpdate {
        StatusItemVisibilityRules.firstLaunchAfterUpdate(
            alreadyMarked: marked, hasSeenOnboarding: onboarding, setting: setting, islandDisplayAttached: island
        )
    }

    func testAnUpdateWithAnIslandDisplayAndNoStoredSettingOpensTheIsland() {
        XCTAssertEqual(afterUpdate(), .openIsland)
    }

    /// A 4.0 user with only an external display: the item was forced on there and goes now. 4.0
    /// decided nothing on that setup and stored no marker, so this launch opens the island once.
    func testAnUpdateOnASetupWithoutANotchOpensTheIslandOnce() {
        let island = StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.externalRight])
        XCTAssertEqual(afterUpdate(island: island), .openIsland)
    }

    func testOnlyTheFirstLaunchOpensIt() {
        XCTAssertEqual(afterUpdate(marked: true), .nothing)
    }

    /// Marked, not merely skipped: the launch after the tour must not open it either.
    func testANewInstallHasTheTourAndNeverGetsTheOpen() {
        XCTAssertEqual(afterUpdate(onboarding: false), .markOnly)
        XCTAssertEqual(afterUpdate(onboarding: false, island: false), .markOnly)
    }

    func testAStoredSettingOfEitherKindNeverGetsTheOpen() {
        XCTAssertEqual(afterUpdate(setting: true), .markOnly)
        XCTAssertEqual(afterUpdate(setting: false), .markOnly)
        XCTAssertEqual(afterUpdate(setting: false, island: false), .markOnly)
    }

    /// The item is still there. Unmarked: a later launch with a display showing the island still needs it.
    func testWithNoIslandDisplayNothingHappensAndALaterLaunchDecides() {
        XCTAssertEqual(afterUpdate(island: false), .nothing)
        XCTAssertEqual(afterUpdate(island: true), .openIsland)
    }

    func testTheOpenLeavesTheKeyboardWithTheAppInFront() {
        XCTAssertFalse(IslandEntry.ear(displayID: 1).becomesKey, "the launch opens as an ear does, not as a click")
    }
}
