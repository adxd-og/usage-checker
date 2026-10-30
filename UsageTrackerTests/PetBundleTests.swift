import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Manifest contract" and § 3.9 "Manifest validation": a
/// test over the built app bundle requires exactly the expected animals, every palette defining
/// every used role, every required animation and the ear head. Reads the test host, the built
/// Omelette.app, as KeepAwakeBundleTests does. The roster is § 3.5 "Roster at 4.0", the table
/// P4's art validator checked. Roles a palette declares and no map uses are printed, never
/// failed.
final class PetBundleTests: XCTestCase {
    private let roster: [String: [String]] = [
        "cat": ["cream", "ginger", "tuxedo"],
        "dog": ["black-white", "cream", "tan"],
        "duck": ["mallard", "white", "yellow"],
        "raccoon": ["brown", "grey", "silver"],
    ]

    func testEachPetIsAFolderWithItsManifestInTheAppsResources() throws {
        let pets = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Pets", isDirectory: true)
        for animal in roster.keys.sorted() {
            let manifest = pets.appendingPathComponent(animal, isDirectory: true).appendingPathComponent("pet.json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "no \(manifest.path)")
        }
    }

    func testExactlyTheRostersPetsAreBundledAndEachKeepsTheContract() {
        let library = PetLibrary.bundled()
        XCTAssertEqual(library.checks.keys.sorted(), ["cat", "dog", "duck", "raccoon"])
        for animal in library.checks.keys.sorted() {
            let check = library.checks[animal]
            XCTAssertEqual(check?.issues, [], "\(animal): \(check?.issues.map(\.description) ?? [])")
            for note in check?.notes ?? [] {
                print("[pets] \(animal): \(note)")
            }
        }
        XCTAssertEqual(library.animalIDs, ["cat", "dog", "duck", "raccoon"])
    }

    func testEachBundledPetHasTheRostersPalettes() {
        let library = PetLibrary.bundled()
        for (animal, palettes) in roster {
            XCTAssertEqual(library.manifests[animal]?.paletteNames, palettes, animal)
        }
    }
}
