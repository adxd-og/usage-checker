import XCTest
@testable import Omelette

/// The store reads the folder when it changes, not only at a poll (spec 2026-11-02 Claude
/// limits from the status line, § Design › App: "loads … on a DispatchSource file-system
/// event"). Watching makes a missing folder owner-only, as the CLI does; a watch the
/// folder's removal ended is armed again by the next poll's load. These are the package's
/// only tests that wait on the real clock, and never more than five seconds.
final class StatusLineReadingStoreWatchTests: XCTestCase {
    private var root: URL!
    private var store: StatusLineReadingStore?

    /// 2026-09-06 11:20:00 UTC, a Sunday: the store's pinned clock.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusLineReadingStoreWatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await store?.stopWatching()
        try? FileManager.default.removeItem(at: root)
    }

    private func watchingStore(_ folder: URL) async -> StatusLineReadingStore {
        let fixed = now
        let made = StatusLineReadingStore(directoryURL: folder, clock: { fixed })
        store = made
        await made.startWatching()
        return made
    }

    /// Whole, as the CLI writes it (temp file, then rename): the folder's event comes after
    /// the bytes are there.
    private func write(_ reading: StatusLineDrop.Reading, into folder: URL) throws {
        let name = try XCTUnwrap(StatusLineDrop.fileName(sessionID: reading.sessionID))
        try StatusLineDrop.encoder.encode(reading).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func mode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func testWatchingMakesAMissingFolderForItsOwnerOnly() async throws {
        let folder = root.appendingPathComponent("Library/Application Support/UsageTracker/statusline", isDirectory: true)

        _ = await watchingStore(folder)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try mode(folder), 0o700)
    }

    func testAReadingWrittenIntoTheWatchedFolderIsReadBeforeAnyPoll() async throws {
        let folder = root.appendingPathComponent("statusline", isDirectory: true)
        let watched = await watchingStore(folder)

        try write(StatusLineFixture.reading(writtenAt: now.addingTimeInterval(-30)), into: folder)

        let seen = await eventually { await watched.sessions.isEmpty == false }
        XCTAssertTrue(seen, "the folder's event loaded the file; no one called load")
        let sessions = await watched.sessions
        XCTAssertEqual(sessions.map(\.sessionID), [StatusLineFixture.sessionID])
    }

    func testAWatchTheFolderLostIsArmedAgainByTheNextLoad() async throws {
        let folder = root.appendingPathComponent("statusline", isDirectory: true)
        let watched = await watchingStore(folder)
        try FileManager.default.removeItem(at: folder)
        let fixed = now

        let remade = await eventually {
            await watched.load(now: fixed)
            return FileManager.default.fileExists(atPath: folder.path)
        }
        XCTAssertTrue(remade, "a poll after the folder went makes it again and watches it")
        XCTAssertEqual(try mode(folder), 0o700)

        try write(StatusLineFixture.reading(writtenAt: now.addingTimeInterval(-30)), into: folder)
        let seen = await eventually { await watched.sessions.isEmpty == false }
        XCTAssertTrue(seen)
    }

    /// The app's re-merge between polls hangs on this: a load a folder event caused is told
    /// to the listener, after the table moved.
    func testAFolderEventTellsTheListenerAfterTheTableMoved() async throws {
        let folder = root.appendingPathComponent("statusline", isDirectory: true)
        let fixed = now
        let watched = StatusLineReadingStore(directoryURL: folder, clock: { fixed })
        store = watched
        let heard = Heard()
        await watched.startWatching {
            Task { await heard.record(await watched.sessions.map(\.sessionID)) }
        }

        try write(StatusLineFixture.reading(writtenAt: now.addingTimeInterval(-30)), into: folder)

        let told = await eventually { await heard.last == [StatusLineFixture.sessionID] }
        XCTAssertTrue(told, "the listener ran after the load, and saw the new session")
    }
}

/// What the store's listener heard, for the watch test.
private actor Heard {
    private(set) var last: [String]?

    func record(_ ids: [String]) {
        last = ids
    }
}
