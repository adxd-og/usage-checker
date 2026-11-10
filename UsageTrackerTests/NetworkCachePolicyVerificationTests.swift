import XCTest
@testable import Omelette

/// Spec 2026-11-11 no URL cache § Design (Credentialed session, Purge): inputs the executor's
/// `NetworkCachePolicyTests` leave out. The credentialed session is a default configuration
/// in everything but its cache (timeouts, cache policy, cookie handling as today); the purge
/// removes links and not what they point at, keeps going past an item it cannot remove, and
/// leaves a folder that is not a folder alone. The Caches folder is a temp directory; no test
/// calls `apply()`, swaps `URLCache.shared` or makes a request.
final class NetworkCachePolicyVerificationTests: XCTestCase {
    private var root: URL!
    private var caches: URL!
    private var elsewhere: URL!
    private let bundleID = "com.example.brioche-verification"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkCachePolicyVerificationTests-\(UUID().uuidString)")
        caches = root.appendingPathComponent("Caches")
        elsewhere = root.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Locked directories (see the failure test) must be writable again to be removed.
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private var folder: URL { caches.appendingPathComponent(bundleID, isDirectory: true) }

    private func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Credentialed session

    func testTheCredentialedSessionKeepsTheDefaultConfigurationsTimeoutsAndPolicies() {
        let ours = NetworkCachePolicy.uncachedSession.configuration
        let stock = URLSessionConfiguration.default
        XCTAssertNil(ours.urlCache)
        XCTAssertEqual(ours.requestCachePolicy, stock.requestCachePolicy)
        XCTAssertEqual(ours.timeoutIntervalForRequest, stock.timeoutIntervalForRequest)
        XCTAssertEqual(ours.timeoutIntervalForResource, stock.timeoutIntervalForResource)
        XCTAssertEqual(ours.httpShouldSetCookies, stock.httpShouldSetCookies)
        XCTAssertEqual(ours.httpCookieAcceptPolicy, stock.httpCookieAcceptPolicy)
        XCTAssertEqual(ours.httpMaximumConnectionsPerHost, stock.httpMaximumConnectionsPerHost)
        XCTAssertEqual(ours.waitsForConnectivity, stock.waitsForConnectivity)
        XCTAssertEqual(ours.allowsCellularAccess, stock.allowsCellularAccess)
        XCTAssertEqual(ours.tlsMinimumSupportedProtocolVersion, stock.tlsMinimumSupportedProtocolVersion)
    }

    func testTheCredentialedSessionIsTheSameOneEveryClientTakesAndNotTheSharedSession() {
        XCTAssertTrue(NetworkCachePolicy.uncachedSession === NetworkCachePolicy.uncachedSession)
        XCTAssertTrue(HTTPClient().session === HTTPClient().session)
        XCTAssertFalse(HTTPClient().session === URLSession.shared)
    }

    func testTheEmptyCacheIsNotTheSharedOneAndHoldsNothingInUse() {
        XCTAssertFalse(NetworkCachePolicy.emptyCache() === URLCache.shared)
        XCTAssertEqual(NetworkCachePolicy.emptyCache().currentDiskUsage, 0)
        XCTAssertEqual(NetworkCachePolicy.emptyCache().currentMemoryUsage, 0)
    }

    // MARK: Purge

    func testALinkLeftInPlaceOfTheDatabaseIsRemovedAndWhatItPointsAtIsNot() throws {
        let target = elsewhere.appendingPathComponent("precious.db")
        try write(target, "keep me")
        let targetFolder = elsewhere.appendingPathComponent("bodies")
        try write(targetFolder.appendingPathComponent("body"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Cache.db"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("fsCachedData"), withDestinationURL: targetFolder)

        let removed = NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID)

        XCTAssertEqual(removed, ["Cache.db", "fsCachedData"])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: folder.appendingPathComponent("Cache.db").path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep me")
        XCTAssertTrue(exists(targetFolder.appendingPathComponent("body")),
                      "a symlinked bodies folder is unlinked, never emptied")
    }

    func testAnItemThatCannotBeRemovedIsLeftOutOfTheResultAndTheOthersAreStillRemoved() throws {
        // `Cache.db` is (oddly) a folder holding a file inside a read-only folder: removing it fails.
        let locked = folder.appendingPathComponent("Cache.db/locked")
        try write(locked.appendingPathComponent("inner"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try write(folder.appendingPathComponent("Cache.db-shm"))
        try write(folder.appendingPathComponent("Cache.db-wal"))
        try write(folder.appendingPathComponent("fsCachedData/0A1B2C3D"))

        let removed = NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID)

        XCTAssertEqual(removed, ["Cache.db-shm", "Cache.db-wal", "fsCachedData"])
        XCTAssertTrue(exists(locked.appendingPathComponent("inner")))
        XCTAssertFalse(exists(folder.appendingPathComponent("Cache.db-shm")))
        XCTAssertFalse(exists(folder.appendingPathComponent("Cache.db-wal")))
        XCTAssertFalse(exists(folder.appendingPathComponent("fsCachedData")))
    }

    func testAFileStandingWhereTheBundleFolderShouldBeIsLeftAlone() throws {
        try write(folder)
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID), [])
        XCTAssertTrue(exists(folder))
    }

    func testAFolderOfTheSameNameAsTheDatabaseIsRemovedWhole() throws {
        try write(folder.appendingPathComponent("Cache.db/nested/page"))
        try write(folder.appendingPathComponent("fsCachedData/a/b/c"))

        let removed = NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID)

        XCTAssertEqual(removed, ["Cache.db", "fsCachedData"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testThePurgeLeavesTheBundleFolderItselfAndItsSiblingsInPlace() throws {
        try write(folder.appendingPathComponent("Cache.db"))
        try write(folder.appendingPathComponent("WebKit/x"))
        try write(caches.appendingPathComponent("\(bundleID).other/Cache.db"))
        try write(caches.appendingPathComponent("Cache.db"))

        NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID)

        XCTAssertTrue(exists(folder), "the folder holds Sparkle's and WebKit's things; it stays")
        XCTAssertTrue(exists(folder.appendingPathComponent("WebKit/x")))
        XCTAssertTrue(exists(caches.appendingPathComponent("\(bundleID).other/Cache.db")))
        XCTAssertTrue(exists(caches.appendingPathComponent("Cache.db")),
                      "a Cache.db directly in Caches belongs to nobody we know")
    }

    func testThePurgeUsesTheFileManagerItIsGiven() throws {
        final class Recording: FileManager, @unchecked Sendable {
            var removed: [String] = []
            override func removeItem(at URL: URL) throws {
                removed.append(URL.lastPathComponent)
                try super.removeItem(at: URL)
            }
        }
        try write(folder.appendingPathComponent("Cache.db"))
        try write(folder.appendingPathComponent("Cache.db-wal"))
        try write(folder.appendingPathComponent("WebKit/x"))
        let manager = Recording()

        NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID, fileManager: manager)

        XCTAssertEqual(manager.removed, ["Cache.db", "Cache.db-wal"])
    }
}
