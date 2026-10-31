import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.7, plan rulings R2, R19: the chosen pet reaches the model as it is
/// made, and re-choosing the stored pair still counts as Settings' word (Codex's plan review 6).
@MainActor
final class IslandPetModelFollowTests: XCTestCase {
    private final class Source {
        @Published var choice = PetChoice.standard
    }

    private func makeModel() -> IslandPetModel {
        IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
    }

    func testANewChoiceReachesTheModel() {
        let source = Source()
        let model = makeModel()
        model.follow(source.$choice)
        source.choice = PetChoice(animal: "duck", palette: "white")
        XCTAssertEqual(model.choice, PetChoice(animal: "duck", palette: "white"))
    }

    func testTheSameChoiceAgainChangesNothing() {
        let source = Source()
        let model = makeModel()
        model.follow(source.$choice)
        var changes = 0
        let watch = model.objectWillChange.sink { changes += 1 }
        source.choice = PetChoice.standard
        watch.cancel()
        XCTAssertEqual(changes, 0)
    }

    #if DEBUG
    func testReChoosingTheStoredPairEndsDebugsAnimal() {
        let source = Source()
        let model = makeModel()
        model.follow(source.$choice)
        model.showDebugAnimal("duck")
        XCTAssertEqual(model.animal, "duck")
        source.choice = PetChoice.standard
        XCTAssertEqual(model.animal, "cat", "Settings wins, whichever pair it names")
    }
    #endif
}
