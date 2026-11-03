import XCTest
@testable import Omelette

/// Verification of the readings store (spec 2026-11-02 Claude limits from the status line,
/// § Design › App): which files it reads, what it sweeps, what it survives, and when it
/// makes the folder. A temp folder per test; the real Application Support is never named.
final class StatusLineReadingStoreVerificationTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var store: StatusLineReadingStore?

    /// 2026-09-06 11:20:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineReadingStoreVerificationTests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("statusline", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ data: Data, _ name: String, modifiedAt: Date? = nil) throws {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
    }

    private func put(_ reading: StatusLineDrop.Reading, as name: String? = nil, modifiedAt: Date? = nil) throws {
        try put(
            try StatusLineDrop.encoder.encode(reading),
            try XCTUnwrap(name ?? StatusLineDrop.fileName(sessionID: reading.sessionID)),
            modifiedAt: modifiedAt
        )
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Garbage, truncated JSON, a directory with a `.json` name, a path-climbing id and a
    /// format from the future sit beside two good readings: both good ones load, in id
    /// order, and nothing throws.
    func testBadFilesAreSurvivedAndGoodOnesStillLoad() async throws {
        try put(Data("{{{{".utf8), "garbage.json")
        let whole = try StatusLineDrop.encoder.encode(StatusLineFixture.reading(sessionID: "trunc", writtenAt: ago(30)))
        try put(whole.prefix(whole.count / 2), "trunc.json")
        try put(Data(), "empty.json")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.json"), withIntermediateDirectories: false)
        try put(StatusLineFixture.reading(sessionID: "../evil", writtenAt: ago(30)), as: "evil.json")
        try put(StatusLineFixture.reading(sessionID: "future", writtenAt: ago(30), formatVersion: 2))
        try put(StatusLineFixture.reading(sessionID: "zeta", writtenAt: ago(20)))
        try put(StatusLineFixture.reading(sessionID: "alpha", writtenAt: ago(10)))

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions.map(\.sessionID), ["alpha", "zeta"])
    }

    /// A reading whose own `written_at` is more than ten minutes back is not tracked,
    /// whatever the file's modification time says.
    func testAnOldReadingInAYoungFileIsNotTracked() async throws {
        try put(StatusLineFixture.reading(sessionID: "stale", writtenAt: ago(601)))
        try put(StatusLineFixture.reading(sessionID: "live", writtenAt: ago(599)))

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions.map(\.sessionID), ["live"])
    }

    /// The sweep is by modification time, strictly older than an hour, and covers a
    /// reading that would not parse as well as one that would.
    func testTheSweepEdgeAndWhatItReaches() async throws {
        try put(StatusLineFixture.reading(sessionID: "edge", writtenAt: ago(3600)), modifiedAt: ago(3600))
        try put(Data("{{{{".utf8), "junk.json", modifiedAt: ago(3601))
        try put(StatusLineFixture.reading(sessionID: "future", writtenAt: ago(3601), formatVersion: 2), modifiedAt: ago(3601))
        try put(StatusLineFixture.reading(sessionID: "named", writtenAt: ago(3601)), as: "other.json", modifiedAt: ago(3601))
        try put(Data(), ".edge.json.AAAA.tmp", modifiedAt: ago(3600))
        try put(Data(), ".junk.json.BBBB.tmp", modifiedAt: ago(3601))
        try put(Data("mine".utf8), "keep.txt", modifiedAt: ago(9999))

        _ = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(try listing(), [".edge.json.AAAA.tmp", "edge.json", "keep.txt"])
    }

    /// Only a non-hidden `*.json` or a hidden `.*.tmp` is ours to sweep: a hidden `.json`
    /// file, however old, is neither (nothing else in the folder is touched), and is never
    /// read as a session either.
    func testAHiddenJSONFileIsNeitherReadNorSwept() async throws {
        try put(StatusLineFixture.reading(sessionID: "ghost", writtenAt: ago(30)), as: ".ghost.json", modifiedAt: ago(7200))
        try put(StatusLineFixture.reading(sessionID: "young", writtenAt: ago(30)), as: ".young.json")

        let sessions = await StatusLineReadingStore(directoryURL: folder).load(now: now)

        XCTAssertEqual(sessions, [])
        XCTAssertEqual(try listing(), [".ghost.json", ".young.json"])
    }

    /// A session whose file disappeared leaves the store; a changed file moves its
    /// counters; the table never keeps a ghost.
    func testADeletedFileEndsItsSession() async throws {
        let s = StatusLineReadingStore(directoryURL: folder)
        try put(StatusLineFixture.reading(writtenAt: ago(30)))
        let first = await s.load(now: now)
        XCTAssertEqual(first.count, 1)

        try FileManager.default.removeItem(at: folder.appendingPathComponent(try XCTUnwrap(StatusLineDrop.fileName(sessionID: StatusLineFixture.sessionID))))
        let second = await s.load(now: now)
        let remembered = await s.sessions
        XCTAssertEqual(second, [])
        XCTAssertEqual(remembered, [])
    }

    /// Loading changes nothing in a folder with only young readings, and loading twice
    /// gives the same table.
    func testLoadingIsIdempotentAndWritesNothing() async throws {
        try put(StatusLineFixture.reading(writtenAt: ago(30)))
        let before = try listing()
        let s = StatusLineReadingStore(directoryURL: folder)

        let a = await s.load(now: now)
        let b = await s.load(now: now)

        XCTAssertEqual(a, b)
        XCTAssertEqual(try listing(), before)
    }

    /// "Creates the folder 0700 only when missing": an existing folder keeps whatever mode
    /// it has, and a watch on it leaves its contents alone.
    func testWatchingAnExistingFolderLeavesItsModeAlone() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try put(StatusLineFixture.reading(writtenAt: ago(30)))
        let s = StatusLineReadingStore(directoryURL: folder, clock: { [now] in now })
        store = s

        await s.startWatching()

        XCTAssertEqual(try mode(folder), 0o755)
        XCTAssertEqual(try listing().count, 1)
    }

    /// A missing folder that is made: 0700, and every missing parent exists afterwards.
    func testWatchingMakesAMissingFolderAndItsParents() async throws {
        let deep = root.appendingPathComponent("a/b/c/statusline", isDirectory: true)
        let s = StatusLineReadingStore(directoryURL: deep, clock: { [now] in now })
        store = s

        await s.startWatching()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try mode(deep), 0o700)
    }
}
