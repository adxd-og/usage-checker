import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5: each animal is a folder `Pets/<animal>/`
/// with its `pet.json`; the library admits the folders that keep the contract and leaves the
/// others out without losing the rest.
final class PetLibraryVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetLibraryVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pet(_ id: String) -> [String: Any] {
        PetFixture.setting(["id"], to: id, in: PetFixture.manifest())
    }

    func testEveryKindOfBadFolderStaysOutWhileTheGoodOnesLoad() throws {
        try PetFixture.write(pet("ant"), folder: "ant", in: directory)
        try PetFixture.write(pet("bee"), folder: "bee", in: directory)
        try PetFixture.write(pet("elk"), folder: "elk", in: directory)

        let garbage = directory.appendingPathComponent("garbage", isDirectory: true)
        try FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: garbage.appendingPathComponent("pet.json"))

        let manifestIsAFolder = directory.appendingPathComponent("folder-manifest/pet.json", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestIsAFolder, withIntermediateDirectories: true)

        try PetFixture.write(PetFixture.setting(["ear"], to: nil, in: pet("cow")), folder: "cow", in: directory)
        try PetFixture.write(pet("not-dog"), folder: "dog", in: directory)
        try PetFixture.write(pet("eel"), folder: "Eel", in: directory)

        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, ["ant", "bee", "elk"])
        XCTAssertEqual(library.checks["garbage"]?.issues, [.unreadable])
        XCTAssertEqual(library.checks["folder-manifest"]?.issues, [.noManifest])
        XCTAssertEqual(library.checks["cow"]?.issues, [.missingKeys(["ear"])])
        XCTAssertEqual(library.checks["dog"]?.issues, [.idMismatch(id: "not-dog", folder: "dog")])
        XCTAssertEqual(library.checks["Eel"]?.issues, [.idMismatch(id: "eel", folder: "Eel")], "the id is the folder's name, letter for letter")
        XCTAssertEqual(library.checks.count, 8)
        XCTAssertNil(library.manifests["garbage"])
    }

    func testStrayFilesAndHiddenEntriesInsideThePetsFolderDoNotAppearAnywhere() throws {
        try PetFixture.write(pet("ant"), folder: "ant", in: directory)
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("pet.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.checks.keys.sorted(), ["ant"])
        XCTAssertEqual(library.animalIDs, ["ant"])
    }

    func testAPathThatIsAFileGivesNoPets() throws {
        let file = directory.appendingPathComponent("Pets")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(PetLibrary.load(from: file), .empty)
    }

    func testTheNotesOfAPassingPetAreKept() throws {
        var object = PetFixture.setting(["palettes", "grey", "w"], to: "#ffffff", in: pet("ant"))
        object = PetFixture.setting(["palettes", "white", "w"], to: "#fefefe", in: object)
        try PetFixture.write(object, folder: "ant", in: directory)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, ["ant"])
        XCTAssertEqual(library.checks["ant"]?.notes, [.unusedRoles("w")])
    }

    /// `bundled(in:)` reads Contents/Resources/Pets of the bundle it is given, not the app's.
    func testABundleCarriesItsPetsInContentsResourcesPets() throws {
        let app = directory.appendingPathComponent("Fake.app", isDirectory: true)
        let pets = app.appendingPathComponent("Contents/Resources/Pets", isDirectory: true)
        try PetFixture.write(pet("ant"), folder: "ant", in: pets)
        let info = ["CFBundleIdentifier": "test.pets", "CFBundlePackageType": "APPL", "CFBundleName": "Fake"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(PetLibrary.bundled(in: bundle).animalIDs, ["ant"])

        let bare = directory.appendingPathComponent("Bare.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Bare.app/Contents/Info.plist"))
        XCTAssertEqual(PetLibrary.bundled(in: try XCTUnwrap(Bundle(url: directory.appendingPathComponent("Bare.app")))), .empty)
    }
}
