import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5: each animal is a folder `Pets/<animal>/` with its
/// `pet.json`. The library reads every folder once; a folder that breaks the contract stays out
/// of the pets with its check kept, and nothing beside the folders counts.
final class PetLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryFolderWithAManifestThatKeepsTheContractIsLoaded() throws {
        try PetFixture.write(PetFixture.manifest(), folder: "mouse", in: directory)
        try PetFixture.write(PetFixture.setting(["id"], to: "vole", in: PetFixture.manifest()), folder: "vole", in: directory)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, ["mouse", "vole"])
        XCTAssertEqual(library.manifests["vole"]?.id, "vole")
        XCTAssertEqual(library.checks["mouse"]?.issues, [])
    }

    func testAFolderThatBreaksTheContractStaysOutWithItsCheckKept() throws {
        try PetFixture.write(PetFixture.manifest(), folder: "mouse", in: directory)
        try PetFixture.write(PetFixture.manifest(), folder: "rat", in: directory)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, ["mouse"])
        XCTAssertEqual(library.checks["rat"]?.issues, [.idMismatch(id: "mouse", folder: "rat")])
    }

    func testAFolderWithoutAManifestIsReported() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, [])
        XCTAssertEqual(library.checks["empty"]?.issues, [.noManifest])
    }

    func testFilesAndHiddenFoldersBesideThePetsAreIgnored() throws {
        try PetFixture.write(PetFixture.manifest(), folder: "mouse", in: directory)
        try Data("notes".utf8).write(to: directory.appendingPathComponent("README.txt"))
        try PetFixture.write(PetFixture.manifest(), folder: ".mouse", in: directory)
        XCTAssertEqual(PetLibrary.load(from: directory).checks.keys.sorted(), ["mouse"])
    }

    func testADirectoryThatIsNotThereGivesNoPets() {
        XCTAssertEqual(PetLibrary.load(from: directory.appendingPathComponent("nowhere")), .empty)
    }
}
