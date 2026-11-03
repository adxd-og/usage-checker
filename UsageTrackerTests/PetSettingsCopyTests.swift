import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6, § 3.7: Settings › Pet's words. Ears exist only beside the
/// island's notch, physical or virtual (spec 2026-11-03), and the switch says so when no display
/// shows the island.
final class PetSettingsCopyTests: XCTestCase {
    func testTheEarsCaptionSaysWhatTheyShowOrWhyTheyDoNot() {
        XCTAssertEqual(
            PetSettingsCopy.earsCaption(islandDisplayAttached: true),
            "With the island closed: a waiting agent, a signed-out Claude, a limit at 90 %, keep awake."
        )
        XCTAssertEqual(
            PetSettingsCopy.earsCaption(islandDisplayAttached: false),
            "Only while a display shows the island."
        )
    }

    func testOnboardingPointsToTheTabByItsName() {
        XCTAssertEqual(SettingsTab.pet.rawValue, "Pet")
        XCTAssertTrue(PetSettingsCopy.onboardingCaption.contains("Settings › \(SettingsTab.pet.rawValue)"))
    }
}
