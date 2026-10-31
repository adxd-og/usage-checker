import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.6, § 3.7: Settings › Pet's words. Ears exist only beside a notch,
/// and the switch says so when none is attached.
final class PetSettingsCopyTests: XCTestCase {
    func testTheEarsCaptionSaysWhatTheyShowOrWhyTheyDoNot() {
        XCTAssertEqual(
            PetSettingsCopy.earsCaption(notchedDisplayAttached: true),
            "With the island closed: a waiting agent, a signed-out Claude, a limit at 90 %, keep awake."
        )
        XCTAssertEqual(
            PetSettingsCopy.earsCaption(notchedDisplayAttached: false),
            "Only on a display with a notch."
        )
    }

    func testOnboardingPointsToTheTabByItsName() {
        XCTAssertEqual(SettingsTab.pet.rawValue, "Pet")
        XCTAssertTrue(PetSettingsCopy.onboardingCaption.contains("Settings › \(SettingsTab.pet.rawValue)"))
    }
}
