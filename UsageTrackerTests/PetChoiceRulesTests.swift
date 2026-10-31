import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Roster, § 3.7, and the P5d tester's finding F5: the stored
/// animal and palette may go stale when a pack changes, so a tested rule turns them into a pair
/// that exists before anything is warmed or drawn.
final class PetChoiceRulesTests: XCTestCase {
    private static let shipped = PetLibrary.bundled()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetChoiceRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The fixture's art under each folder's name: palettes grey and white.
    private func library(_ folders: [String]) throws -> PetLibrary {
        for folder in folders {
            try PetFixture.write(
                PetFixture.setting(["id"], to: folder, in: PetFixture.manifest()), folder: folder, in: directory
            )
        }
        return PetLibrary.load(from: directory)
    }

    func testAChoiceThePetHasIsKept() {
        let choice = PetChoice(animal: "dog", palette: "black-white")
        XCTAssertEqual(PetChoiceRules.resolved(choice, in: Self.shipped), choice)
    }

    func testAPaletteThePetLostFallsBackToItsFirstPalette() {
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice(animal: "duck", palette: "pink"), in: Self.shipped),
            PetChoice(animal: "duck", palette: "yellow")
        )
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice(animal: "dog", palette: "ginger"), in: Self.shipped),
            PetChoice(animal: "dog", palette: "tan"),
            "another animal's palette name is not this one's"
        )
    }

    func testAnAnimalThePackLostFallsBackToTheCatInGingerNotToThePalettesName() {
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice(animal: "otter", palette: "cream"), in: Self.shipped),
            PetChoice.standard,
            "the cat has a cream too, but it was never chosen for the cat"
        )
    }

    func testWithoutTheCatTheFirstAnimalLeftStands() throws {
        XCTAssertEqual(
            PetChoiceRules.resolved(PetChoice.standard, in: try library(["mouse"])),
            PetChoice(animal: "mouse", palette: "grey")
        )
    }

    func testNoPetsAtAllMeanNothingToShow() {
        XCTAssertNil(PetChoiceRules.resolved(PetChoice.standard, in: .empty))
    }

    func testTheRosterAndItsPalettesComeInTheSpecsOrder() throws {
        XCTAssertEqual(PetChoiceRules.animals(in: Self.shipped), ["cat", "duck", "dog", "raccoon"])
        XCTAssertEqual(PetChoiceRules.palettes(of: try XCTUnwrap(Self.shipped.manifests["cat"])), ["ginger", "cream", "tuxedo"])
        XCTAssertEqual(PetChoiceRules.palettes(of: try XCTUnwrap(Self.shipped.manifests["duck"])), ["yellow", "white", "mallard"])
        XCTAssertEqual(PetChoiceRules.palettes(of: try XCTUnwrap(Self.shipped.manifests["dog"])), ["tan", "black-white", "cream"])
        XCTAssertEqual(PetChoiceRules.palettes(of: try XCTUnwrap(Self.shipped.manifests["raccoon"])), ["grey", "brown", "silver"])
    }

    func testAnAnimalOrPaletteTheTableDoesNotNameComesLastAlphabetically() throws {
        let library = try library(["zebra", "mouse", "cat"])
        XCTAssertEqual(PetChoiceRules.animals(in: library), ["cat", "mouse", "zebra"])
        XCTAssertEqual(PetChoiceRules.palettes(of: try XCTUnwrap(library.manifests["cat"])), ["grey", "white"])
    }

    func testEveryShippedPetResolvesToItself() throws {
        for animal in PetChoiceRules.animals(in: Self.shipped) {
            for palette in PetChoiceRules.palettes(of: try XCTUnwrap(Self.shipped.manifests[animal])) {
                let choice = PetChoice(animal: animal, palette: palette)
                XCTAssertEqual(PetChoiceRules.resolved(choice, in: Self.shipped), choice)
            }
        }
    }

    func testAPaletteNameReadsAsAWord() {
        XCTAssertEqual(PetChoiceRules.paletteName("ginger"), "Ginger")
        XCTAssertEqual(PetChoiceRules.paletteName("black-white"), "Black-white")
    }
}
