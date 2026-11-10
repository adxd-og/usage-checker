import XCTest
@testable import Omelette

/// Spec 2026-11-11 no URL cache § Design (Shared cache, Credentialed session, Purge): the
/// cache that holds nothing, the session that has none, and the removal of what an earlier
/// version left in `<Caches>/<bundle id>/`. The Caches folder is a temp directory: no test
/// touches the real one or swaps `URLCache.shared`.
final class NetworkCachePolicyTests: XCTestCase {
    private var caches: URL!
    private let bundleID = "com.example.brioche-tests"

    override func setUpWithError() throws {
        caches = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkCachePolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
    }

    private func make(_ relative: String, directory: Bool = false) throws {
        let url = caches.appendingPathComponent(relative)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: caches.appendingPathComponent(relative).path)
    }

    func testTheCacheThatReplacesTheSharedOneHoldsNothing() {
        let cache = NetworkCachePolicy.emptyCache()
        XCTAssertEqual(cache.memoryCapacity, 0)
        XCTAssertEqual(cache.diskCapacity, 0)
    }

    func testThePurgeRemovesTheCacheDatabaseItsSidecarsAndItsBodiesAndNothingElse() throws {
        try make("\(bundleID)/Cache.db")
        try make("\(bundleID)/Cache.db-shm")
        try make("\(bundleID)/Cache.db-wal")
        try make("\(bundleID)/fsCachedData/0A1B2C3D")
        try make("\(bundleID)/WebKit/NetworkCache/blob")
        try make("\(bundleID)/org.sparkle-project.Sparkle/appcast")
        try make("\(bundleID)/Cache.db.backup")
        try make("com.example.other/Cache.db")

        let removed = NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID)

        XCTAssertEqual(removed, ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"])
        XCTAssertFalse(exists("\(bundleID)/Cache.db"))
        XCTAssertFalse(exists("\(bundleID)/Cache.db-shm"))
        XCTAssertFalse(exists("\(bundleID)/Cache.db-wal"))
        XCTAssertFalse(exists("\(bundleID)/fsCachedData"))
        XCTAssertTrue(exists("\(bundleID)/WebKit/NetworkCache/blob"))
        XCTAssertTrue(exists("\(bundleID)/org.sparkle-project.Sparkle/appcast"))
        XCTAssertTrue(exists("\(bundleID)/Cache.db.backup"))
        XCTAssertTrue(exists("com.example.other/Cache.db"), "another app's cache is not ours")
    }

    func testAPurgeWithNothingToRemoveIsQuiet() throws {
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID), [])
        try make("\(bundleID)/Cache.db-wal")
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID), ["Cache.db-wal"])
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: bundleID), [])
    }

    func testAnEmptyBundleIDPurgesNothing() throws {
        // `<Caches>/` + "" is the Caches folder itself: a `Cache.db` there is somebody else's.
        try make("Cache.db")
        XCTAssertEqual(NetworkCachePolicy.purge(cachesDirectory: caches, bundleID: ""), [])
        XCTAssertTrue(exists("Cache.db"))
    }

    func testUnderTestsApplyChangesNothing() {
        // The test host has the app's bundle id: an `apply()` that ran here would swap the
        // process-wide cache under every other test and delete the user's files. The bundle
        // id passed names no folder, so a broken guard shows as a swapped cache, never as a
        // deleted file.
        let before = URLCache.shared
        NetworkCachePolicy.apply(bundleID: "com.example.brioche-tests-no-such-app")
        XCTAssertTrue(URLCache.shared === before)
    }
}
