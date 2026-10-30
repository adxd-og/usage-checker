#if DEBUG
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)", the Debug trigger: what the pet's
/// context menu lists — the shown animal's events by id, "Play all in order", the four animals — and
/// that under Reduce Motion it says so and plays nothing (OWNER 4). Debug builds only.
final class PetDebugMenuRulesTests: XCTestCase {
    private func manifest(events: [String]) throws -> PetManifest {
        let object = PetFixture.setting(["events"], to: events.map { PetFixture.event(id: $0) }, in: PetFixture.manifest())
        return try XCTUnwrap(PetManifestValidator.check(try PetFixture.data(object), folder: PetFixture.id).manifest)
    }

    private func library(_ pets: [String: [String]]) throws -> PetLibrary {
        PetLibrary(manifests: try pets.mapValues { try manifest(events: $0) }, checks: [:])
    }

    func testItListsTheShownAnimalsEventsByIdInTheManifestsOrder() throws {
        let pets = try library(["cat": ["yarn", "box"], "duck": ["takeoff"]])
        let cat = PetDebugMenuRules.menu(shown: "cat", library: pets, animates: true, reduceMotion: false)
        XCTAssertEqual(cat.eventIDs, ["yarn", "box"])
        XCTAssertNil(cat.note)
        XCTAssertTrue(cat.canPlay)
        XCTAssertEqual(PetDebugMenuRules.menu(shown: "duck", library: pets, animates: true, reduceMotion: false).eventIDs, ["takeoff"])
        XCTAssertEqual(PetDebugMenuRules.playAllTitle, "Play all in order")
    }

    func testNothingPlaysWithTheGateOffOrWithNoEvents() throws {
        let pets = try library(["cat": ["yarn"], "dog": []])
        XCTAssertFalse(PetDebugMenuRules.menu(shown: "cat", library: pets, animates: false, reduceMotion: false).canPlay)
        XCTAssertFalse(PetDebugMenuRules.menu(shown: "dog", library: pets, animates: true, reduceMotion: false).canPlay)
    }

    func testUnderReduceMotionItSaysSoAndStillListsThem() throws {
        let menu = PetDebugMenuRules.menu(
            shown: "cat", library: try library(["cat": ["yarn"]]), animates: false, reduceMotion: true
        )
        XCTAssertEqual(menu.note, "Reduce Motion is on: events do not play")
        XCTAssertEqual(menu.eventIDs, ["yarn"])
        XCTAssertFalse(menu.canPlay)
    }

    func testTheAnimalsComeInTheirOrderAndOnlyThoseTheLibraryHas() throws {
        let menu = PetDebugMenuRules.menu(
            shown: "duck", library: try library(["raccoon": [], "duck": [], "cat": []]), animates: true, reduceMotion: false
        )
        XCTAssertEqual(menu.animals, [
            PetDebugMenu.Animal(id: "cat", isShown: false),
            PetDebugMenu.Animal(id: "duck", isShown: true),
            PetDebugMenu.Animal(id: "raccoon", isShown: false),
        ])
        let shipped = PetDebugMenuRules.menu(shown: "cat", library: .bundled(), animates: true, reduceMotion: false)
        XCTAssertEqual(shipped.animals.map(\.id), ["cat", "duck", "dog", "raccoon"])
    }

    /// R14: every shipped animal shows in a palette it has.
    func testAnAnimalWithoutTheDefaultPaletteShowsItsFirst() throws {
        let shipped = PetLibrary.bundled().manifests
        XCTAssertEqual(try XCTUnwrap(shipped["cat"]).paletteNames.contains(PetHabitatRules.palette), true)
        XCTAssertEqual(PetDebugMenuRules.palette(of: try XCTUnwrap(shipped["cat"])), "ginger")
        XCTAssertEqual(PetDebugMenuRules.palette(of: try XCTUnwrap(shipped["dog"])), "black-white")
        XCTAssertEqual(PetDebugMenuRules.palette(of: try XCTUnwrap(shipped["duck"])), "mallard")
        XCTAssertEqual(PetDebugMenuRules.palette(of: try XCTUnwrap(shipped["raccoon"])), "brown")
    }
}
#endif
