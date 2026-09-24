import XCTest
@testable import Omelette

/// A windowless pay-as-you-go account's spend through a failed poll and a relaunch.
/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "Pay-as-you-go: 'has content' is `!buckets.isEmpty || (weekCost ?? 0) > 0` in
/// `retainingLastGoodServices` and `LastKnownStore.remember`; a spend-only retained
/// service dims like any other."
final class PayAsYouGoRetentionTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private var t1: Date { t0.addingTimeInterval(600) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayAsYouGoRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Enterprise pay-as-you-go without a weekly budget, as `AppState.applyPayAsYouGo`
    /// leaves it: no window at all, the week's local spend is the whole reading.
    private func payAsYouGo(at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Claude Enterprise",
                         buckets: [], weekCost: 31.7, at: date)
    }

    /// The same account on a failed poll: `applyPayAsYouGo` only runs for an `.ok`
    /// Claude, so the failure carries no dollars of its own.
    private func failedClaude(at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", plan: nil, buckets: [],
                         state: .error, stateMessage: "500: internal error", at: date)
    }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    private func carriedOver() throws -> ServiceSnapshot {
        let merged = AppState.retainingLastGoodServices(
            previous: poll([payAsYouGo(at: t0)], at: t0),
            next: poll([failedClaude(at: t1)], at: t1),
            stored: [:]
        )
        return try XCTUnwrap(merged.services.first)
    }

    func testSpendAloneIsContent() {
        XCTAssertTrue(payAsYouGo(at: t0).hasContent)
        XCTAssertTrue(Fixture.snapshot(buckets: [Fixture.bucket(id: "five_hour", percent: 1)]).hasContent)
        XCTAssertFalse(Fixture.snapshot(buckets: [], weekCost: nil).hasContent)
        XCTAssertFalse(Fixture.snapshot(buckets: [], weekCost: 0).hasContent)
        XCTAssertTrue(LastKnownService(from: payAsYouGo(at: t0), order: 0).hasContent)
    }

    func testAFailedPollKeepsTheWeeksSpend() throws {
        let claude = try carriedOver()
        XCTAssertEqual(claude.weekCost, 31.7)
        XCTAssertEqual(claude.plan, "Claude Enterprise")
        XCTAssertTrue(claude.buckets.isEmpty)
        XCTAssertEqual(claude.state, .error)
        XCTAssertEqual(claude.stateMessage, "500: internal error")
        XCTAssertTrue(claude.isCarriedOver)
        XCTAssertTrue(claude.isRetained, "spend-only numbers dim like any other")
        XCTAssertEqual(claude.retainedAt, t0)
    }

    func testTheStoredSpendSpeaksForTheFirstPollAfterARelaunch() throws {
        let merged = AppState.retainingLastGoodServices(
            previous: .empty,
            next: poll([failedClaude(at: t1)], at: t1),
            stored: ["claude": LastKnownService(from: payAsYouGo(at: t0), order: 0)]
        )
        let claude = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(claude.weekCost, 31.7)
        XCTAssertTrue(claude.isRetained)
        XCTAssertEqual(claude.retainedAt, t0)
    }

    func testTheSeededSpendIsRetainedFromTheFirstFrame() throws {
        let seeded = AppState.seededSnapshot(
            from: ["claude": LastKnownService(from: payAsYouGo(at: t0), order: 0)]
        )
        let claude = try XCTUnwrap(seeded.services.first)
        XCTAssertEqual(claude.weekCost, 31.7)
        XCTAssertEqual(claude.state, .notRunning)
        XCTAssertTrue(claude.isCarriedOver)
        XCTAssertTrue(claude.isRetained)
    }

    func testASpendOnlyReadingSurvivesARelaunch() async throws {
        await LastKnownStore(fileURL: fileURL).remember([payAsYouGo(at: t0)])

        let reloaded = await LastKnownStore(fileURL: fileURL).load()

        let entry = try XCTUnwrap(reloaded["claude"], "a windowless account's spend is a reading worth keeping")
        XCTAssertEqual(entry.weekCost, 31.7)
        XCTAssertTrue(entry.buckets.isEmpty)
        XCTAssertEqual(entry.plan, "Claude Enterprise")
        XCTAssertEqual(entry.fetchedAt, t0)
    }

    func testAFailedServiceIsStillNotRemembered() async throws {
        let carried = try carriedOver()
        await LastKnownStore(fileURL: fileURL).remember([carried])

        let reloaded = await LastKnownStore(fileURL: fileURL).load()
        XCTAssertTrue(reloaded.isEmpty, "the carried-over copy is not a new reading")
    }

    func testASignedOutGrokKeepsItsLiveSpendAndIsNotRetained() throws {
        // GrokProvider keeps the local log's spend on a failed poll. Those dollars are
        // this poll's: taking the previous poll's copy as a "last good reading" would
        // freeze them, and calling them retained would stamp live numbers "as of".
        let earlier = Fixture.snapshot(id: "grok", displayName: "Grok", plan: nil, buckets: [], weekCost: 6.9,
                                       state: .notSignedIn, stateMessage: "Sign in", at: t0)
        let current = Fixture.snapshot(id: "grok", displayName: "Grok", plan: nil, buckets: [], weekCost: 7.2,
                                       state: .notSignedIn, stateMessage: "Sign in", at: t1)

        let merged = AppState.retainingLastGoodServices(
            previous: poll([earlier], at: t0), next: poll([current], at: t1), stored: [:]
        )

        let grok = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(grok.weekCost, 7.2, "a signed-out Grok's own spend keeps moving")
        XCTAssertEqual(grok.fetchedAt, t1)
        XCTAssertFalse(grok.isCarriedOver)
        XCTAssertFalse(grok.isRetained)
    }

    func testForgettingASpendOnlyReadingDropsIt() throws {
        let carried = try carriedOver()
        let snapshot = UsageSnapshot(services: [carried], fetchedAt: t1, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "claude", from: snapshot)

        let claude = try XCTUnwrap(after.services.first)
        XCTAssertNil(claude.weekCost)
        XCTAssertFalse(claude.isRetained)
        XCTAssertEqual(claude.state, .error, "the chip still says why it went quiet")
    }
}
