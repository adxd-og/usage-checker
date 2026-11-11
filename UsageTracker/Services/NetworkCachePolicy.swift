import Foundation

/// The app keeps no HTTP cache (spec 2026-11-11 no URL cache). `URLSession`'s cache stores a
/// cacheable answer on disk together with its request, the `Authorization` header included:
/// Claude's OAuth token and Grok's credential were found in `Cache.db` that way. Nothing in
/// the app reads a cached answer — every poll asks — so the cache is switched off whole and
/// what an earlier version left is removed.
enum NetworkCachePolicy {
    /// What `URLCache` keeps in `<Caches>/<bundle id>/`: the database, its two sidecars and
    /// the folder of larger bodies. The folder's other tenants (WebKit, Sparkle) are not ours.
    static let cacheItems = ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"]

    /// A cache that holds nothing, in memory or on disk. Set as `URLCache.shared` it covers
    /// every session that takes the shared cache: ours, CodexBarCore's and Sparkle's.
    static func emptyCache() -> URLCache {
        URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)
    }

    /// For requests of ours that carry a credential (`HTTPClient`): a default session with
    /// no cache at all, so they do not depend on `apply()` having run first. Cookies,
    /// credential storage and timeouts are the default ones, as before.
    static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Removes the cache an earlier version left in `<cachesDirectory>/<bundleID>/` and
    /// returns the names it removed. Files, not rows: a deleted row's bytes stay in the
    /// database's free pages. Nothing there is the normal case. A bundle id that is not one
    /// path component removes nothing (`isOnePathComponent`).
    @discardableResult
    static func purge(
        cachesDirectory: URL, bundleID: String, fileManager: FileManager = .default
    ) -> [String] {
        guard isOnePathComponent(bundleID) else { return [] }
        let folder = cachesDirectory.appendingPathComponent(bundleID, isDirectory: true)
        return cacheItems.filter { name in
            let url = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { return false }
            return (try? fileManager.removeItem(at: url)) != nil
        }
    }

    /// Whether `bundleID` names one folder inside Caches. Empty or `.` is the Caches folder
    /// itself, `..` its parent, a `/` another folder, and a NUL ends the path early where the
    /// file system reads it: none of those `Cache.db` files is ours.
    static func isOnePathComponent(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID != "." && bundleID != ".."
            && !bundleID.contains("/") && !bundleID.contains("\0")
    }

    /// At launch, before the first request: no shared cache from here on, and the old one
    /// gone. Does nothing under tests — the test host has the app's bundle id, so this would
    /// delete the user's files and swap a process-wide cache under every other test.
    static func apply(
        bundleID: String? = Bundle.main.bundleIdentifier, fileManager: FileManager = .default
    ) {
        guard !AppEnvironment.isRunningTests else { return }
        URLCache.shared = emptyCache()
        guard let bundleID,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        purge(cachesDirectory: caches, bundleID: bundleID, fileManager: fileManager)
    }
}
