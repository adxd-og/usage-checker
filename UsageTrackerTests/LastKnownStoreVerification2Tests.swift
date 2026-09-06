import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `LastKnownService.hasSameValues` / `LastKnownStore` (item 5 of the batch brief).
///
/// The executor's own `LastKnownStoreTests.swift` already covers the write-fails-
/// then-succeeds dirty flag (`testAWriteThatFailedIsRetriedOnTheNextPoll`) and a
/// provider renamed with its icon and account label changed all at once
/// (`testARenamedProviderIsWrittenEvenWithTheSameNumbers`). These tests instead
/// isolate one field at a time — icon alone, account label alone — so a comparison
/// that accidentally checks the wrong field (or omits one) would fail even though a
/// test that changes several fields together would not catch it.
final class LastKnownStoreVerification2Tests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let stored = Date(timeIntervalSince1970: 1_788_100_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastKnownStoreVerification2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    private func antigravity(icon: String = "sparkles", accountLabel: String? = nil, at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", icon: icon, plan: "Antigravity Pro",
            accountLabel: accountLabel,
            buckets: [Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62)],
            weekCost: 3.5, at: date
        )
    }

    func testAnIconChangeAloneIsWrittenEvenWithEveryOtherFieldTheSame() async throws {
        let s = store()
        await s.remember([antigravity(icon: "sparkles", at: stored)])

        await s.remember([antigravity(icon: "bolt", at: stored.addingTimeInterval(60))])

        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.icon, "bolt", "an icon-only change must survive to disk")
    }

    func testAnAccountLabelChangeAloneIsWrittenEvenWithEveryOtherFieldTheSame() async throws {
        let s = store()
        await s.remember([antigravity(accountLabel: nil, at: stored)])

        await s.remember([antigravity(accountLabel: "work@example.com", at: stored.addingTimeInterval(60))])

        let reloaded = await store().load()
        XCTAssertEqual(
            reloaded["antigravity"]?.accountLabel, "work@example.com",
            "signing in to an account after the fact must not be swallowed by the unchanged-numbers throttle"
        )
    }

    func testAnAccountLabelClearedAloneIsWrittenToo() async throws {
        // The reverse direction: signing out drops the label back to nil. If the
        // comparison only checks "is now non-nil" this direction would miss it.
        let s = store()
        await s.remember([antigravity(accountLabel: "work@example.com", at: stored)])

        await s.remember([antigravity(accountLabel: nil, at: stored.addingTimeInterval(60))])

        let reloaded = await store().load()
        XCTAssertNil(reloaded["antigravity"]?.accountLabel, "signing out must be persisted, not treated as unchanged")
    }

    func testNothingAtAllChangingReallyDoesNotRewriteTheFetchedAtStamp() async throws {
        // The negative case, to make sure the isolated-field tests above are not
        // passing because *everything* gets rewritten regardless of `hasSameValues`.
        let s = store()
        await s.remember([antigravity(at: stored)])
        await s.remember([antigravity(at: stored.addingTimeInterval(60))])

        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.fetchedAt, stored, "identical values on every field must not restamp")
    }
}
