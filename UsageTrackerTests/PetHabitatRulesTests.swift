import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (the 150 pt habitat, the sky following the local clock),
/// § 3.5 (Rendering: whole beads on the device-pixel grid; Runtime: motion never leaves the
/// habitat, no bit while the pointer is over the right column) and the owner's notes of
/// 2026-10-30 (the column has no fill and no edge; the pet always stands on the floor): which pet,
/// its size, the floor it walks, where the sprite is drawn, when the pointer is over the content
/// beside it, and the mood and the sky at a given minute.
final class PetHabitatRulesTests: XCTestCase {
    private let retina = PetScaleRules.Scale(pixelsPerBead: 3, backingScale: 2)
    private let plain = PetScaleRules.Scale(pixelsPerBead: 1, backingScale: 1)
    private let side: CGFloat = 52.5

    func testTheCatInGingerLivesThereUntilSettingsLetsTheUserChoose() {
        XCTAssertEqual(PetHabitatRules.animal, "cat")
        XCTAssertEqual(PetHabitatRules.palette, "ginger")
        XCTAssertNotNil(
            PetLibrary.bundled().manifests[PetHabitatRules.animal]?.palettes[PetHabitatRules.palette],
            "the bundle carries it"
        )
    }

    func testThePetIs52Point5PointsOnARetinaDisplayAnd35OnAPlainOne() {
        XCTAssertEqual(PetHabitatRules.scale(petBeads: 35, backingScale: 2), retina)
        XCTAssertEqual(retina.points(beads: 35), 52.5)
        XCTAssertEqual(PetHabitatRules.scale(petBeads: 35, backingScale: 1), plain)
        XCTAssertEqual(plain.points(beads: 35), 35)
    }

    func testTheFloorBesideTheCatIs65BeadsOnARetinaDisplay() {
        XCTAssertEqual(PetHabitatRules.roamBeads(petBeads: 35, scale: retina), 65)
        XCTAssertEqual(PetHabitatRules.roamBeads(petBeads: 35, scale: plain), 115)
        XCTAssertEqual(PetHabitatRules.roamBeads(petBeads: 35, scale: PetScaleRules.Scale(pixelsPerBead: 4, backingScale: 3)), 77)
        XCTAssertEqual(PetHabitatRules.roamBeads(petBeads: 200, scale: retina), 0, "a pet wider than the column walks nowhere")
    }

    func testThePetAlwaysStandsOnTheFloorAboveTheMoodLine() {
        XCTAssertEqual(PetHabitatRules.floorY(height: 600, petSide: side), 566)
        XCTAssertEqual(PetHabitatRules.floorY(height: 900, petSide: side), 866, "the column's bottom, whatever its height")
        XCTAssertEqual(PetHabitatRules.floorY(height: 40, petSide: side), side, "never above the pet's own height")
    }

    func testTheSpriteSitsOnWholeBeadsAndDevicePixels() {
        XCTAssertEqual(
            PetHabitatRules.origin(xBeads: 10, footY: 566, petBeads: 35, roamBeads: 65, scale: retina),
            CGPoint(x: 15, y: 513.5)
        )
        XCTAssertEqual(PetHabitatRules.origin(xBeads: 80, footY: 566, petBeads: 35, roamBeads: 65, scale: retina).x, 97.5, "kept on the floor")
        XCTAssertEqual(PetHabitatRules.origin(xBeads: -3, footY: 566, petBeads: 35, roamBeads: 65, scale: retina).x, 0)
        XCTAssertEqual(
            PetHabitatRules.origin(
                xBeads: 10, footY: PetHabitatRules.floorY(height: 600.3, petSide: side),
                petBeads: 35, roamBeads: 65, scale: retina
            ).y,
            514,
            "513.8 to the nearest device pixel"
        )
        XCTAssertEqual(
            PetHabitatRules.origin(xBeads: 10, footY: 566, petBeads: 35, roamBeads: 115, scale: plain),
            CGPoint(x: 10, y: 531)
        )
    }

    func testOnlyThePointerOverTheRightColumnCounts() {
        let content = CGSize(width: 612, height: 640)
        XCTAssertEqual(PetHabitatRules.contentColumnMinX, 176)
        XCTAssertTrue(PetHabitatRules.pointerOverContent(CGPoint(x: 176, y: 0), contentSize: content))
        XCTAssertTrue(PetHabitatRules.pointerOverContent(CGPoint(x: 612, y: 640), contentSize: content))
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: 175.5, y: 300), contentSize: content), "over the habitat")
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: 300, y: -1), contentSize: content), "the strip beside the camera")
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: 300, y: 641), contentSize: content))
        XCTAssertFalse(PetHabitatRules.pointerOverContent(CGPoint(x: 613, y: 300), contentSize: content))
    }

    /// Codex review 5: with keep awake on and nothing else changing, 22:00 turns the mood and the
    /// sky to night on the minute.
    func testNightAndTheSkyTurnOnTheMinuteWithNothingElseChanging() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        let locale = Locale(identifier: "en_GB")
        let midnight = Date(timeIntervalSince1970: 1_792_972_800)
        let deadline = midnight.addingTimeInterval(26 * 3_600)
        let input = PetMoodInput(
            sessions: [], services: [], enabledIDs: nil, claudeBinaryFound: true,
            keepAwake: .armed(deadline: deadline, floorEnabled: true)
        )
        func scene(at now: Date) -> PetHabitatScene {
            PetHabitatRules.scene(input, petName: "Cat", mode: .used, now: now, calendar: calendar, locale: locale)
        }
        func shown(_ mood: PetMood, at now: Date) -> PetMoodPresentation {
            PetMoodRules.presentation(of: mood, petName: "Cat", mode: .used, now: now, calendar: calendar, locale: locale)
        }
        let evening = midnight.addingTimeInterval(22 * 3_600 - 1)
        let night = midnight.addingTimeInterval(22 * 3_600)
        XCTAssertEqual(scene(at: evening), PetHabitatScene(presentation: shown(.idle, at: evening), sky: .dusk), "21:59:59")
        XCTAssertEqual(
            scene(at: night), PetHabitatScene(presentation: shown(.keepAwakeNight(deadline: deadline), at: night), sky: .night),
            "22:00:00: asleep, the moon up"
        )
        XCTAssertEqual(scene(at: night).presentation.pose, .sleep)
    }
}
