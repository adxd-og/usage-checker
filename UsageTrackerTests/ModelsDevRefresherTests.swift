import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Pricing: "`ModelsDevPricing` stamps `lastAttemptAt` after the fetch result so a
/// failed fetch with no cache retries sooner than 24 h." Stamped before the fetch, an
/// offline first launch with nothing on disk left the live table empty — and every
/// Codex turn at $0 — for a day (report B #1). No test here touches the network or the
/// real Application Support: the fetch is scripted and the cache file is a temp one.
final class ModelsDevRefresherTests: XCTestCase {
    private var directory: URL!
    /// 2026-09-06 12:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_788_696_000)
    private let prices = [
        "gpt-5.6": ModelPrice(
            inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
            cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
        )
    ]

    /// The network, scripted: one answer per call, in order, and a count of the calls.
    /// Read and written under a lock — the refresher calls it from its own actor.
    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<[String: ModelPrice], Error>]
        private var count = 0

        init(_ answers: [Result<[String: ModelPrice], Error>]) {
            self.answers = answers
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func answer() throws -> [String: ModelPrice] {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            return try answers.removeFirst().get()
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelsDevRefresherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        ModelPricing.updateDynamic([:])
    }

    private var cacheURL: URL { directory.appendingPathComponent("models-dev-pricing.json") }

    func testAFailedFetchWithNothingOnDiskIsTriedAgainAfterAQuarterOfAnHour() async {
        let network = Network([.failure(URLError(.notConnectedToInternet)), .success(prices)])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: { try network.answer() })

        await refresher.refreshIfStale(now: t0)
        XCTAssertEqual(network.calls, 1)
        XCTAssertNil(ModelPricing.dynamicLookup(for: "gpt-5.6"), "offline, nothing cached: no rates yet")

        await refresher.refreshIfStale(now: t0.addingTimeInterval(60))
        XCTAssertEqual(network.calls, 1, "the next poll does not hammer a network that just failed")

        await refresher.refreshIfStale(now: t0.addingTimeInterval(ModelsDevPricing.retryAfterFailure))
        XCTAssertEqual(network.calls, 2, "a quarter of an hour later, not a day")
        XCTAssertNotNil(ModelPricing.dynamicLookup(for: "gpt-5.6"))
        XCTAssertNotNil(ModelsDevPricing.readCache(at: cacheURL), "a good answer is kept on disk")
    }

    func testAGoodFetchIsNotRepeatedForADay() async {
        let network = Network([.success(prices), .success(prices)])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: { try network.answer() })

        await refresher.refreshIfStale(now: t0)
        await refresher.refreshIfStale(now: t0.addingTimeInterval(23 * 3600))
        XCTAssertEqual(network.calls, 1)

        // A day on, the disk copy is a day old too: the check fetches again.
        await refresher.refreshIfStale(now: t0.addingTimeInterval(ModelsDevPricing.maxCacheAge))
        XCTAssertEqual(network.calls, 2)
    }

    func testAFreshCopyOnDiskPricesWithoutAFetch() async {
        ModelsDevPricing.writeCache(
            ModelsDevPricing.Cache(fetchedAt: t0.addingTimeInterval(-3600), prices: prices),
            to: cacheURL
        )
        let network = Network([])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: { try network.answer() })

        await refresher.refreshIfStale(now: t0)
        await refresher.refreshIfStale(now: t0.addingTimeInterval(3600))

        XCTAssertEqual(network.calls, 0)
        XCTAssertNotNil(ModelPricing.dynamicLookup(for: "gpt-5.6"))
    }

    /// The stamp used to be set before the fetch, which also kept a second poll out
    /// while a slow fetch was on the wire. Stamped after the answer, that is the
    /// in-flight flag's job.
    func testTwoChecksThatOverlapFetchOnce() async {
        let network = Network([.success(prices), .success(prices)])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: {
            try await Task.sleep(nanoseconds: 100_000_000)
            return try network.answer()
        })

        // A local, not `t0`: reading the property inside `async let` would send the
        // test case itself into the child tasks.
        let at = t0
        async let first: Void = refresher.refreshIfStale(now: at)
        async let second: Void = refresher.refreshIfStale(now: at)
        _ = await (first, second)

        XCTAssertEqual(network.calls, 1)
    }

    func testTheNextCheckIsScheduledFromTheAnswer() {
        XCTAssertEqual(ModelsDevPricing.nextAttempt(after: .fetched, at: t0), t0.addingTimeInterval(24 * 3600))
        XCTAssertEqual(ModelsDevPricing.nextAttempt(after: .freshCache, at: t0), t0.addingTimeInterval(24 * 3600))
        XCTAssertEqual(ModelsDevPricing.nextAttempt(after: .failed, at: t0), t0.addingTimeInterval(15 * 60))
    }
}
