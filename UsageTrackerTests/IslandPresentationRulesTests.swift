import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 (Presentation), § 3.9 (`IslandPresentationRules`) and
/// D12: one output for the island's width, its habitat, its ears and the ear-to-habitat
/// morph, from notch presence, screen width, Pet on and ears on.
final class IslandPresentationRulesTests: XCTestCase {
    private func present(
        notch: Bool = true, width: CGFloat, pet: Bool = true, ears: Bool = true
    ) -> IslandPresentationRules.Presentation {
        IslandPresentationRules.presentation(notchPresent: notch, screenWidth: width, petOn: pet, earsOn: ears)
    }

    func testThe14InchGetsThe640IslandWithItsHabitatAndEars() {
        XCTAssertEqual(
            present(width: 1512),
            .init(width: 640, showsHabitat: true, showsEars: true, morphEligible: true)
        )
    }

    func testA1700PointScreenGetsThe720Island() {
        XCTAssertEqual(present(width: 1700).width, 720)
        XCTAssertEqual(present(width: 1728).width, 720)
        XCTAssertEqual(present(width: 1699.5).width, 640)
    }

    func testBelow1420TheIslandIs560AndHasNoHabitat() {
        let narrow = present(width: 1419)
        XCTAssertEqual(narrow.width, 560)
        XCTAssertFalse(narrow.showsHabitat)
        XCTAssertFalse(narrow.morphEligible, "no habitat to morph into")
        XCTAssertTrue(narrow.showsEars)
        XCTAssertEqual(present(width: 1420).width, 640)
        XCTAssertTrue(present(width: 1420).showsHabitat)
    }

    func testThePanelFollowsTheSameWidthsAndDropsTheHabitatBelow1420() {
        XCTAssertEqual(
            present(notch: false, width: 1280),
            .init(width: 560, showsHabitat: false, showsEars: false, morphEligible: false)
        )
        XCTAssertEqual(
            present(notch: false, width: 2560),
            .init(width: 720, showsHabitat: true, showsEars: false, morphEligible: false)
        )
    }

    func testWithThePetOffTheEarsStayButNothingMorphs() {
        XCTAssertEqual(
            present(width: 1512, pet: false),
            .init(width: 640, showsHabitat: false, showsEars: true, morphEligible: false)
        )
    }

    func testWithTheEarsOffThereIsNoEarToMorph() {
        XCTAssertEqual(
            present(width: 1512, ears: false),
            .init(width: 640, showsHabitat: true, showsEars: false, morphEligible: false)
        )
    }

    func testTheWidthAloneFollowsTheSameBreakpoints() {
        XCTAssertEqual(IslandPresentationRules.width(screenWidth: 1512), 640)
        XCTAssertEqual(IslandPresentationRules.width(screenWidth: 1728), 720)
        XCTAssertEqual(IslandPresentationRules.width(screenWidth: 1280), 560)
    }
}
