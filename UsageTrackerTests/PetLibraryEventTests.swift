import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)": a bad event stays out of the
/// library's pet with its reason in the check, and the pet is loaded.
final class PetLibraryEventTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetLibraryEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAPetWithABadEventLoadsWithoutItAndItsCheckSaysWhy() throws {
        let bad = PetFixture.setting(["fps"], to: 99, in: PetFixture.event(id: "bad"))
        let object = PetFixture.setting(["events"], to: [bad, PetFixture.event()], in: PetFixture.manifest())
        try PetFixture.write(object, folder: PetFixture.id, in: directory)
        let library = PetLibrary.load(from: directory)
        XCTAssertEqual(library.animalIDs, [PetFixture.id])
        XCTAssertEqual(library.manifests[PetFixture.id]?.events.map(\.id), ["hop"])
        XCTAssertEqual(library.checks[PetFixture.id]?.issues, [])
        XCTAssertEqual(library.checks[PetFixture.id]?.notes, [.eventDropped(id: "bad", issues: [.fps])])
    }
}
