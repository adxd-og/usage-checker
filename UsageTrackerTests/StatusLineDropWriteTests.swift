import XCTest
@testable import Omelette

/// Writing the drop (spec 2026-11-02 Claude limits from the status line,
/// § Design › Wire): `<directory>/<session_id>.json`, the folder made owner-only (0700)
/// on every write and the file 0600, a temp file in the same folder renamed over the
/// old one, and every failure silent. Each test gets its own temp folder; `home` is
/// never created.
final class StatusLineDropWriteTests: XCTestCase {
    private var root: URL!
    private var dropURL: URL!
    private var home: URL!

    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineDropWriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dropURL = root.appendingPathComponent("statusline", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // One test makes the drop folder immutable; clear the flag before removing.
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: dropURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func parsed(_ json: String) -> StatusLineInput {
        StatusLineInput.parse(Data(json.utf8))
    }

    @discardableResult
    private func write(_ input: StatusLineInput, now: Date? = nil, environment: [String: String] = [:]) -> StatusLineDrop.Outcome {
        StatusLineDrop.write(input, to: dropURL, now: now ?? self.now, environment: environment, home: home)
    }

    private var file: URL {
        dropURL.appendingPathComponent(StatusLineFixture.sessionID + ".json")
    }

    private func readBack(_ url: URL) throws -> StatusLineDrop.Reading {
        try StatusLineDrop.decoder.decode(StatusLineDrop.Reading.self, from: Data(contentsOf: url))
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dropURL.path).sorted()
    }

    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func testTheSessionsReadingIsWrittenUnderItsID() throws {
        let input = parsed(StatusLineFixture.payload())

        XCTAssertEqual(write(input), .written)

        XCTAssertEqual(
            try readBack(file),
            StatusLineDrop.reading(from: input, now: now, configDir: home.path + "/.claude")
        )
        XCTAssertEqual(
            try listing(), [StatusLineFixture.sessionID + ".json"],
            "the temporary file is gone: renamed, not copied"
        )
    }

    /// First run on a Mac where nothing made the folders yet: the parents are made with
    /// the default mode, the drop folder itself for its owner only.
    func testTheFolderIsMadeOwnerOnlyWithItsParents() throws {
        let deep = root.appendingPathComponent(
            "Library/Application Support/UsageTracker/statusline", isDirectory: true
        )

        XCTAssertEqual(
            StatusLineDrop.write(
                parsed(StatusLineFixture.payload()), to: deep, now: now, environment: [:], home: home
            ),
            .written
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: deep.appendingPathComponent(StatusLineFixture.sessionID + ".json").path)
        )
        XCTAssertEqual(try mode(deep), 0o700)
    }

    /// The reading is the user's business: nobody else on the Mac can open the file,
    /// whatever the folder around it allows.
    func testTheFileIsReadableOnlyByItsOwner() throws {
        XCTAssertEqual(write(parsed(StatusLineFixture.payload())), .written)

        XCTAssertEqual(try mode(file), 0o600)
    }

    func testAnExistingFolderIsWrittenInto() throws {
        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)

        XCTAssertEqual(write(parsed(StatusLineFixture.payload())), .written)
        XCTAssertEqual(try listing(), [StatusLineFixture.sessionID + ".json"])
    }

    /// A folder someone else made — an older build, P2's reader, the user — is
    /// tightened on the next write, not trusted as it is.
    func testAnExistingFolderIsMadeOwnerOnly() throws {
        try FileManager.default.createDirectory(
            at: dropURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(try mode(dropURL), 0o755, "the fixture: a folder others can open")

        XCTAssertEqual(write(parsed(StatusLineFixture.payload())), .written)

        XCTAssertEqual(try mode(dropURL), 0o700)
    }

    /// Claude Code re-runs the line on every message and every minute: the newest
    /// reading replaces the last one whole, never merged with it.
    func testANewReadingReplacesTheLastOneWhole() throws {
        write(parsed(StatusLineFixture.payload()))
        let later = parsed(
            StatusLineFixture.payload(rateLimits: #"{"five_hour":{"used_percentage":31,"resets_at":1788703200}}"#)
        )

        XCTAssertEqual(write(later, now: now.addingTimeInterval(60)), .written)

        let reading = try readBack(file)
        XCTAssertEqual(reading.fiveHour?.usedPercent, 31)
        XCTAssertNil(reading.sevenDay, "the new file, not a merge with the old one")
        XCTAssertEqual(reading.writtenAt, now.addingTimeInterval(60))
        XCTAssertEqual(try listing(), [StatusLineFixture.sessionID + ".json"])
    }

    func testEachSessionKeepsItsOwnFile() throws {
        let other = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

        write(parsed(StatusLineFixture.payload()))
        write(parsed(StatusLineFixture.payload(sessionID: other)))

        XCTAssertEqual(try listing(), [StatusLineFixture.sessionID + ".json", other + ".json"].sorted())
        XCTAssertEqual(try readBack(dropURL.appendingPathComponent(other + ".json")).sessionID, other)
    }

    /// No window or no session: no file, and not even the folder.
    func testWithoutAWindowOrASessionNothingIsWritten() throws {
        for json in [
            StatusLineFixture.payload(rateLimits: nil),
            StatusLineFixture.payload(rateLimits: #"{"spend_limit":{"used_percentage":12,"resets_at":1788703200}}"#),
            #"{"rate_limits":"# + StatusLineFixture.rateLimits + "}",
            "",
        ] {
            XCTAssertEqual(write(parsed(json)), .nothingToWrite, json)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropURL.path))
    }

    /// An id that cannot be a file name writes nothing, inside the folder or beside it.
    func testAnUnsafeSessionIDWritesNothingAnywhere() throws {
        for id in ["../escape", "a.b", "a/b", "a b", "café"] {
            XCTAssertEqual(write(parsed(StatusLineFixture.payload(sessionID: id))), .nothingToWrite, id)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// A folder that cannot be made, or one that will not take a file: `.failed`,
    /// nothing thrown, nothing left behind. The second folder is immutable
    /// (`chflags uchg`), which refuses the chmod and the new file alike even to its
    /// owner; a 0500 folder would not do, since the write's own chmod reopens it.
    func testAFolderThatCannotBeMadeOrWrittenIsASilentFailure() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        XCTAssertEqual(
            StatusLineDrop.write(
                parsed(StatusLineFixture.payload()), to: blocker, now: now, environment: [:], home: home
            ),
            .failed
        )
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "x")

        try FileManager.default.createDirectory(at: dropURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: dropURL.path)
        XCTAssertEqual(write(parsed(StatusLineFixture.payload())), .failed)
        XCTAssertEqual(try listing(), [], "no temporary file left behind")
    }

    /// The rename is the last step; when it fails, the temporary file goes with it.
    func testARenameThatFailsTakesItsTemporaryFileWithIt() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        XCTAssertEqual(write(parsed(StatusLineFixture.payload())), .failed)
        XCTAssertEqual(try listing(), [StatusLineFixture.sessionID + ".json"], "only the folder in the file's place")
    }

    /// The config folder comes from the environment the writer is handed, not from the
    /// test host's.
    func testTheConfigDirComesFromTheEnvironmentItIsHanded() throws {
        let work = root.appendingPathComponent("work-claude", isDirectory: true)

        write(parsed(StatusLineFixture.payload()), environment: ["CLAUDE_CONFIG_DIR": work.path])

        XCTAssertEqual(try readBack(file).configDir, work.path)
    }
}
