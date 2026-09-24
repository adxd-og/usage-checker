import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A items 5 and 7 at the rule
/// level. Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design,
/// Retention — "Pay-as-you-go: 'has content' is `!buckets.isEmpty || (weekCost ?? 0) >
/// 0` in `retainingLastGoodServices` and `LastKnownStore.remember`; a spend-only
/// retained service dims like any other."
///
/// The executor's `PayAsYouGoRetentionTests` exercises the same rules through
/// `AppState`'s full retention pipeline. This file drives `ServiceSnapshot.hasContent`,
/// `isRetained` and `spendHeadline` directly as a truth table (values the executor's
/// fixtures never hit — a negative-adjacent boundary, an artificially constructed
/// `.ok` + `isCarriedOver` combination, a spend limit alongside empty buckets) and
/// checks `LastKnownStore.remember`'s change detection across repeated spend-only
/// writes.
final class ServiceRetentionRulesVerificationTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let t0 = Date(timeIntervalSince1970: 1_788_100_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceRetentionRulesVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - hasContent truth table

    func testHasContentAtTheWeekCostBoundary() {
        XCTAssertFalse(Fixture.snapshot(buckets: [], weekCost: 0.0).hasContent, "exactly zero is not spend")
        XCTAssertTrue(Fixture.snapshot(buckets: [], weekCost: 0.01).hasContent, "one cent is a reading")
        XCTAssertFalse(Fixture.snapshot(buckets: [], weekCost: -4.0).hasContent, "a negative figure should never occur, but is not content either")
    }

    func testHasContentIsTrueWheneverThereAreBucketsRegardlessOfWeekCost() {
        let withBoth = Fixture.snapshot(buckets: [Fixture.bucket(id: "five_hour", percent: 1)], weekCost: 0)
        XCTAssertTrue(withBoth.hasContent)
    }

    // MARK: - isRetained does not require isCarriedOver to be set by construction

    func testIsRetainedFromBucketsAloneNeedsNoCarriedOverFlag() {
        // A service that failed this poll but happens to have reported some buckets
        // anyway (a partial answer) is `isRetained` by the buckets alone; `isCarriedOver`
        // is only how a *windowless* spend-only reading gets the same treatment.
        var service = Fixture.snapshot(buckets: [Fixture.bucket(id: "five_hour", percent: 12)], state: .error)
        XCTAssertFalse(service.isCarriedOver)
        XCTAssertTrue(service.isRetained)

        service = Fixture.snapshot(buckets: [], weekCost: 9.9, state: .error)
        XCTAssertFalse(service.isRetained, "spend alone, on a service that failed this poll, is not retained until something actually carried it over")
    }

    func testAnOkServiceIsNeverRetainedEvenIfMarkedCarriedOver() {
        // `isCarriedOver` alone never overrides `state == .ok`: the guard order in
        // `isRetained` is `state != .ok && (...)`, not the other way round.
        var service = Fixture.snapshot(buckets: [], weekCost: 31.7, state: .ok)
        service.isCarriedOver = true
        XCTAssertTrue(service.isCarriedOver)
        XCTAssertFalse(service.isRetained, "a service the app is calling healthy this poll cannot also be shown as last-known")
    }

    // MARK: - spendHeadline

    func testSpendHeadlineIsNilForAFailedServiceEvenWithAPositiveWeekCost() {
        // Distinguishes `spendHeadline` from the bare "weekCost > 0" check the old
        // code used: a failed, non-retained service must not show a number that reads
        // as either live or explicitly last-known.
        let neverRetained = Fixture.snapshot(buckets: [], weekCost: 6.5, state: .notSignedIn)
        XCTAssertFalse(neverRetained.isRetained)
        XCTAssertNil(neverRetained.spendHeadline)
    }

    func testSpendHeadlineIgnoresBucketsWhenPresent() {
        // Not part of the pay-as-you-go path in practice (a windowed service does not
        // also carry a `weekCost` headline in the UI), but the rule itself is a pure
        // guard and should not silently invent a headline for a windowed service.
        let windowed = Fixture.snapshot(
            buckets: [Fixture.bucket(id: "five_hour", percent: 10)], weekCost: 4.0, state: .ok
        )
        XCTAssertEqual(windowed.spendHeadline, 4.0, "the guard only checks state and weekCost, not buckets — callers gate on `hero == nil` themselves")
    }

    // MARK: - LastKnownStore.remember, spend-only, change detection

    func testRememberingTheSameSpendTwiceWritesOnlyOnce() async throws {
        let store = LastKnownStore(fileURL: fileURL)
        let service = Fixture.snapshot(id: "claude", buckets: [], weekCost: 18.4, at: t0)

        await store.remember([service])
        let firstWrite = try Data(contentsOf: fileURL)

        // A later poll with the exact same figures should not touch the file's
        // content (fetchedAt included — `hasSameValues` intentionally excludes it, but
        // an unchanged fetchedAt should not add churn either).
        await store.remember([service])
        let secondWrite = try Data(contentsOf: fileURL)

        XCTAssertEqual(firstWrite, secondWrite, "identical spend-only readings should not rewrite the file")
    }

    func testASpendChangeOnAWindowlessAccountIsPersisted() async throws {
        let store = LastKnownStore(fileURL: fileURL)
        await store.remember([Fixture.snapshot(id: "claude", buckets: [], weekCost: 18.4, at: t0)])
        await store.remember([Fixture.snapshot(id: "claude", buckets: [], weekCost: 22.1, at: t0.addingTimeInterval(600))])

        let reloaded = await LastKnownStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded["claude"]?.weekCost, 22.1, "the newer spend figure replaces the old one")
    }

    func testASpendOnlyEntryDisappearingFromTheStoreOnForget() async throws {
        let store = LastKnownStore(fileURL: fileURL)
        await store.remember([Fixture.snapshot(id: "claude", buckets: [], weekCost: 18.4, at: t0)])
        await store.forget(serviceID: "claude")

        let reloaded = await LastKnownStore(fileURL: fileURL).load()
        XCTAssertNil(reloaded["claude"], "the same forget path a windowed service uses also clears a spend-only entry")
    }
}
