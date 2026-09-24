import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Pricing
/// (report B #1): "`ModelsDevPricing` stamps `lastAttemptAt` after the fetch result so
/// a failed fetch with no cache retries sooner than 24 h." Written independently of
/// `ModelsDevRefresherTests.swift`: its own boundary checks on `nextAttempt`/
/// `refreshIfStale` and a `Task.detached`-based overlap race rather than `async let`.
final class ModelsDevPricingVerificationTests: XCTestCase {
    private var directory: URL!
    /// 2026-09-10 09:00 UTC, arbitrary and fixed.
    private let t0 = Date(timeIntervalSince1970: 1_789_030_800)
    private let priceRow = [
        "verify-model-refresher": ModelPrice(
            inputPerM: 0.5, outputPerM: 4, cacheReadPerM: 0.05, cacheCreate5mPerM: 0.6, cacheCreate1hPerM: 1
        )
    ]

    /// A scripted network: one answer per call in order, call count under a lock —
    /// the refresher's actor calls it from its own isolation.
    private final class ScriptedNetwork: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<[String: ModelPrice], Error>]
        private(set) var callCount = 0

        init(_ answers: [Result<[String: ModelPrice], Error>]) { self.answers = answers }

        func next() throws -> [String: ModelPrice] {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            guard !answers.isEmpty else { throw URLError(.timedOut) }
            return try answers.removeFirst().get()
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelsDevPricingVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        ModelPricing.updateDynamic([:])
    }

    private var cacheURL: URL { directory.appendingPathComponent("verify-models-dev-cache.json") }

    // MARK: - Pure scheduling rule

    func testTheSameQuarterHourBoundaryOnFailureAndTheSameDayBoundaryOnSuccess() {
        XCTAssertEqual(
            ModelsDevPricing.nextAttempt(after: .failed, at: t0),
            t0.addingTimeInterval(15 * 60),
            "a failed fetch retries in a quarter of an hour, not a day"
        )
        XCTAssertEqual(ModelsDevPricing.nextAttempt(after: .fetched, at: t0), t0.addingTimeInterval(24 * 3600))
        XCTAssertEqual(ModelsDevPricing.nextAttempt(after: .freshCache, at: t0), t0.addingTimeInterval(24 * 3600))
    }

    // MARK: - The actor's own schedule, exercised at the boundary

    func testAFailedFetchIsNotRetriedOneSecondEarlyButIsExactlyOnTime() async {
        let network = ScriptedNetwork([.failure(URLError(.notConnectedToInternet)), .success(priceRow)])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: { try network.next() })

        await refresher.refreshIfStale(now: t0)
        XCTAssertEqual(network.calls, 1)

        await refresher.refreshIfStale(now: t0.addingTimeInterval(15 * 60 - 1))
        XCTAssertEqual(network.calls, 1, "one second short of the retry window: still holding off")

        await refresher.refreshIfStale(now: t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(network.calls, 2, "exactly on the boundary: due")
        XCTAssertNotNil(ModelPricing.dynamicLookup(for: "verify-model-refresher"))
    }

    /// After a SUCCESS, the schedule reverts to the 24-hour cadence even though the
    /// process just came off a failure-driven quarter-hour retry a moment earlier.
    func testASuccessRightAfterAFailureGoesBackToTheDayLongCadence() async {
        let network = ScriptedNetwork([
            .failure(URLError(.notConnectedToInternet)), .success(priceRow), .success(priceRow),
        ])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: { try network.next() })

        await refresher.refreshIfStale(now: t0)
        await refresher.refreshIfStale(now: t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(network.calls, 2, "the failure, then the retry that succeeds")

        await refresher.refreshIfStale(now: t0.addingTimeInterval(15 * 60 + 3600))
        XCTAssertEqual(network.calls, 2, "an hour after the SUCCESS is nowhere near its 24h schedule")

        await refresher.refreshIfStale(now: t0.addingTimeInterval(15 * 60 + 24 * 3600))
        XCTAssertEqual(network.calls, 3, "24h after the success, due again")
    }

    /// A concurrent race, not `async let`: two tasks call `refreshIfStale` on the same
    /// actor instance at (as near as the runtime allows) the same time, and only one
    /// fetch must go out.
    func testConcurrentDetachedCallsStillFetchOnlyOnce() async {
        let network = ScriptedNetwork([.success(priceRow), .success(priceRow)])
        let refresher = ModelsDevRefresher(cacheURL: cacheURL, fetch: {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try network.next()
        })
        let now = t0

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await refresher.refreshIfStale(now: now) }
            }
        }

        XCTAssertEqual(network.calls, 1, "four overlapping callers, one fetch")
    }
}
