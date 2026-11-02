import XCTest
@testable import Omelette

/// The folder `brioche statusline` writes, as the app reads it (spec 2026-11-02 Claude
/// limits from the status line, § Design › App): only non-hidden `*.json` files, each under
/// its own session's name, advanced through the freshness rules; a reading or a temp file
/// older than an hour is swept; a missing folder is an empty one. A temp folder per test.
final class StatusLineReadingStoreTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    /// 2026-09-06 11:20:00 UTC, a Sunday. A file the test writes carries the real clock's
    /// modification time, later than this, so the sweep leaves it alone unless the test
    /// dates it.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineReadingStoreTests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ reading: StatusLineDrop.Reading, as name: String? = nil, modifiedAt: Date? = nil) throws {
        let url = folder.appendingPathComponent(try XCTUnwrap(name ?? StatusLineDrop.fileName(sessionID: reading.sessionID)))
        try StatusLineDrop.encoder.encode(reading).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testAReadingInTheFolderBecomesItsSession() async throws {
        try write(StatusLineFixture.reading(writtenAt: ago(30)))

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions, [StatusLineFreshnessRules.advance(nil, with: StatusLineFixture.reading(writtenAt: ago(30)))])
    }

    func testTheStoreKeepsEachSessionBetweenLoads() async throws {
        let store = StatusLineReadingStore(directoryURL: folder)
        try write(StatusLineFixture.reading(writtenAt: ago(120)))
        await store.load(now: ago(100))
        try write(StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60)))

        let sessions = await store.load(now: now)

        XCTAssertEqual(sessions.map(\.asOf), [ago(60)], "dated by the file in which its API time grew")
    }

    /// After a launch every session is first sight again: the counters it last saw went
    /// with the process.
    func testAFreshStoreStartsEverySessionOver() async throws {
        try write(StatusLineFixture.reading(writtenAt: ago(120)))
        await StatusLineReadingStore(directoryURL: folder).load(now: ago(100))
        try write(StatusLineFixture.reading(totalAPIDurationMs: 21_400, writtenAt: ago(60)))

        let relaunched = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(relaunched.map(\.asOf), [nil])
    }

    func testAWritersTempFileIsNeverRead() async throws {
        let name = ".\(StatusLineFixture.sessionID).json.\(UUID().uuidString).tmp"
        try write(StatusLineFixture.reading(writtenAt: ago(30)), as: name)

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions, [])
        XCTAssertEqual(try listing(), [name], "young, so not swept either")
    }

    func testAFileThatIsNotASessionsReadingIsSkipped() async throws {
        try Data("not json".utf8).write(to: folder.appendingPathComponent("garbage.json"))
        try write(StatusLineFixture.reading(sessionID: "aaaa", writtenAt: ago(30), formatVersion: 2))
        try write(StatusLineFixture.reading(sessionID: "bbbb", writtenAt: ago(30)), as: "cccc.json")

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions, [], "garbage, a format this build does not know, a reading under another session's name")
    }

    func testOldReadingsAndLeftoverTempFilesAreSwept() async throws {
        try write(StatusLineFixture.reading(sessionID: "old", writtenAt: ago(3601)), modifiedAt: ago(3601))
        try write(StatusLineFixture.reading(sessionID: "young", writtenAt: ago(60)), modifiedAt: ago(60))
        try write(StatusLineFixture.reading(sessionID: "a", writtenAt: ago(3601)), as: ".a.json.0F3A.tmp", modifiedAt: ago(3601))
        try write(StatusLineFixture.reading(sessionID: "b", writtenAt: ago(60)), as: ".b.json.0F3A.tmp", modifiedAt: ago(60))
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: notes)
        try FileManager.default.setAttributes([.modificationDate: ago(7200)], ofItemAtPath: notes.path)

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(try listing(), [".b.json.0F3A.tmp", "notes.txt", "young.json"], "nothing else in the folder is ours to touch")
        XCTAssertEqual(sessions.map(\.sessionID), ["young"])
    }

    func testAMissingFolderIsAnEmptyOneAndIsNotMade() async throws {
        let nowhere = root.appendingPathComponent("nowhere", isDirectory: true)

        let sessions = await StatusLineReadingStore(directoryURL: nowhere).load(now: now)

        XCTAssertEqual(sessions, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: nowhere.path), "only a watch makes the folder")
    }
}
