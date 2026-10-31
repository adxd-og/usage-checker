import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Roster, § 3.7: the island shows the stored choice, made real
/// by `PetChoiceRules`; a new choice lets go of the old pet's event. In Debug the menu's animal holds
/// in memory until Settings speaks (plan ruling R2).
@MainActor
final class IslandPetModelChoiceTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()
    private let t0 = PetRuntimeFixture.t0

    private func makeModel(_ choice: PetChoice = .standard) -> IslandPetModel {
        IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 }, choice: choice)
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    func testTheIslandShowsTheChoiceItWasGiven() {
        let choice = PetChoice(animal: "dog", palette: "black-white")
        XCTAssertEqual(makeModel(choice).shown(in: Self.shipped), choice)
    }

    func testAStaleChoiceIsShownAsAPetThatExists() {
        XCTAssertEqual(
            makeModel(PetChoice(animal: "duck", palette: "pink")).shown(in: Self.shipped),
            PetChoice(animal: "duck", palette: "yellow")
        )
        XCTAssertEqual(makeModel(PetChoice(animal: "otter", palette: "x")).shown(in: Self.shipped), .standard)
        XCTAssertNil(makeModel().shown(in: .empty))
    }

    func testAChangePublishesOnceAndTheSameChoiceNothing() {
        let model = makeModel()
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        model.setChoice(.standard)
        XCTAssertEqual(changes, 0)
        model.setChoice(PetChoice(animal: "duck", palette: "white"))
        XCTAssertEqual(changes, 1)
        watch.cancel()
        XCTAssertEqual(model.choice, PetChoice(animal: "duck", palette: "white"))
    }

    func testAChangeOfPetIsHeardAndTheSameChoiceIsNot() {
        let model = makeModel()
        let heard = Counter()
        model.onPetChange = { heard.count += 1 }
        model.setChoice(.standard)
        XCTAssertEqual(heard.count, 0)
        model.setChoice(PetChoice(animal: "duck", palette: "white"))
        XCTAssertEqual(heard.count, 1)
    }

    #if DEBUG
    func testANewChoiceLetsGoOfTheOldPetsEvent() {
        let model = makeModel()
        model.show(phase: .open)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let idle = PetMoodRules.presentation(
            of: .idle, petName: "Cat", mode: .used, now: t0, calendar: calendar, locale: Locale(identifier: "en_GB")
        )
        func bit(_ seconds: TimeInterval) -> PetBit? {
            model.keeper.frame(
                at: t0 + seconds, presentation: idle, animations: PetRuntimeFixture.animations,
                roamBeads: PetRuntimeFixture.roam, events: [PetEventFixture.climb]
            )?.bit
        }
        model.keeper.play(eventID: "climb")
        XCTAssertEqual(bit(0.5), .event("climb"))
        model.setChoice(PetChoice(animal: "duck", palette: "white"))
        XCTAssertNil(bit(0.625))
    }

    func testDebugsAnimalHoldsUntilSettingsSpeaksEvenWithTheSameChoice() {
        let model = makeModel()
        model.showDebugAnimal("duck")
        XCTAssertEqual(model.shown(in: Self.shipped), PetChoice(animal: "duck", palette: "mallard"))
        model.setChoice(.standard)
        XCTAssertEqual(model.shown(in: Self.shipped), .standard, "the latest word wins")
        XCTAssertEqual(model.animal, "cat")
    }

    func testDebugsAnimalTheLibraryLacksIsIgnored() {
        let model = makeModel()
        model.showDebugAnimal("otter")
        XCTAssertEqual(model.shown(in: Self.shipped), .standard)
    }
    #endif
}
