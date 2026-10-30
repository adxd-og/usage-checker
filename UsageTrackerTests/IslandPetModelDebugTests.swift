import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": the island shows the default pet;
/// in Debug the menu can show another animal, in memory only, and the runtime lets go of the old
/// animal's event. The model publishes only a change: only the habitat observes it.
@MainActor
final class IslandPetModelDebugTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0

    private func makeModel() -> IslandPetModel {
        IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
    }

    func testTheIslandShowsTheDefaultPet() throws {
        let model = makeModel()
        XCTAssertEqual(model.animal, PetHabitatRules.animal)
        let cat = try XCTUnwrap(PetLibrary.bundled().manifests["cat"])
        XCTAssertEqual(model.palette(of: cat), PetHabitatRules.palette)
    }

    #if DEBUG
    func testTheMenuShowsAnotherAnimalInMemoryOnly() throws {
        let model = makeModel()
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        model.showDebugAnimal("duck")
        XCTAssertEqual(model.animal, "duck")
        XCTAssertEqual(changes, 1)
        model.showDebugAnimal("duck")
        XCTAssertEqual(changes, 1, "the same animal publishes nothing")
        watch.cancel()
        let duck = try XCTUnwrap(PetLibrary.bundled().manifests["duck"])
        XCTAssertEqual(model.palette(of: duck), "mallard")
        XCTAssertEqual(makeModel().animal, PetHabitatRules.animal, "nothing is kept")
    }

    func testSwitchingAnimalLetsGoOfTheOldOnesEvent() {
        let model = makeModel()
        model.show(phase: .open)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
        let events = [PetEventFixture.climb]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let idle = PetMoodRules.presentation(
            of: .idle, petName: "Cat", mode: .used, now: t0, calendar: calendar, locale: Locale(identifier: "en_GB")
        )
        func bit(_ seconds: TimeInterval) -> PetBit? {
            model.keeper.frame(
                at: t0 + seconds, presentation: idle, animations: PetRuntimeFixture.animations,
                roamBeads: PetRuntimeFixture.roam, events: events
            )?.bit
        }
        model.keeper.play(eventID: "climb")
        XCTAssertEqual(bit(0.5), .event("climb"))
        model.showDebugAnimal("duck")
        XCTAssertNil(bit(0.625))
    }
    #endif
}
