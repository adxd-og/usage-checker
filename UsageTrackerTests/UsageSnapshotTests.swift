import XCTest
@testable import Omelette

/// `headlinePercent` is the single number the menu bar, the widget and the hero ring all
/// show, so which window it picks is the most user-visible rule in the app.
final class UsageSnapshotTests: XCTestCase {

    // MARK: - headlinePercent

    func testTheWeeklyCapLeadsOverAScopedOneAndAPromoPool() {
        // 97% on "Fable only" and 99% on a free bonus are both louder numbers, and both
        // are the wrong answer to "can I keep working?". The all-models weekly is.
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "five_hour", percent: 40, kind: .session),
            Fixture.bucket(id: "seven_day", percent: 55, kind: .weekly),
            Fixture.bucket(id: "seven_day_fable", percent: 97, kind: .modelSpecific),
            Fixture.bucket(id: "seven_day_promotional", percent: 99, kind: .weekly),
        ])
        XCTAssertEqual(service.headlinePercent, 55)
    }

    func testAnEnabledSpendLimitCompetesForTheHeadline() {
        let service = Fixture.snapshot(
            plan: "Enterprise",
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2)
        )
        XCTAssertEqual(service.headlinePercent, 78.2, accuracy: 0.0001)
    }

    func testADisabledSpendLimitDoesNot() {
        let service = Fixture.snapshot(
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2)
        )
        XCTAssertEqual(service.headlinePercent, 40)
    }

    func testScopedWindowsLeadWhenTheyAreAllTheAccountHas() {
        // Gemini expresses every limit as a per-model daily quota; excluding them would
        // leave the menu bar at 0% on an account that is nearly out.
        let service = Fixture.snapshot(id: "gemini", buckets: [
            Fixture.bucket(id: "gemini_pro", percent: 91, kind: .modelSpecific),
            Fixture.bucket(id: "gemini_flash", percent: 12, kind: .modelSpecific),
        ])
        XCTAssertEqual(service.headlinePercent, 91)
    }

    func testAPromoPoolLeadsWhenItIsAllThereIs() {
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "seven_day_promotional", percent: 99, kind: .weekly)
        ])
        XCTAssertEqual(service.headlinePercent, 99)
    }

    func testAnAccountWithNoWindowsAtAllReadsAsZero() {
        XCTAssertEqual(Fixture.snapshot().headlinePercent, 0)
        XCTAssertEqual(UsageSnapshot.empty.headlinePercent, 0)
    }

    /// The account on 2026-10-04: the menu bar said 92 % in red — the credit pool —
    /// while the plan's worst window was the weekly at 69 %.
    private var cloudCreditsAccount: ServiceSnapshot {
        Fixture.snapshot(buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 7, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly),
            Fixture.bucket(id: "seven_day_fable", label: "Fable only", percent: 20, kind: .modelSpecific),
            Fixture.cloudCredits,
        ])
    }

    func testACloudSessionCreditPoolNeverDrivesTheHeadline() {
        XCTAssertEqual(cloudCreditsAccount.headlinePercent, 69)
    }

    func testACreditPoolDoesNotOutrankAScopedCapInTheFallback() {
        // No core window at all: the scoped cap is this account's limit, the pool is money.
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "seven_day_fable", percent: 20, kind: .modelSpecific),
            Fixture.cloudCredits,
        ])
        XCTAssertEqual(service.headlinePercent, 20)
    }

    func testACreditPoolLeadsOnlyWhenItIsAllTheAccountHas() {
        XCTAssertEqual(Fixture.snapshot(buckets: [Fixture.cloudCredits]).headlinePercent, 92.368272, accuracy: 0.0001)
    }

    func testTheSnapshotHeadlineIsTheWorstProvidersHeadline() {
        let snapshot = UsageSnapshot(
            services: [
                Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 20, kind: .weekly)]),
                Fixture.snapshot(id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 77, kind: .session)]),
            ],
            fetchedAt: Date(),
            isStale: false,
            lastError: nil
        )
        XCTAssertEqual(snapshot.headlinePercent, 77)
    }

    // MARK: - isPromotional

    func testPromotionalIsRecognizedByIdOrByLabel() {
        XCTAssertTrue(Fixture.bucket(id: "seven_day_omelette_promotional", label: "Claude Design").isPromotional)
        XCTAssertTrue(Fixture.bucket(id: "bonus_pool", label: "Promo credits").isPromotional)
        // Case doesn't matter — the server has shipped both.
        XCTAssertTrue(Fixture.bucket(id: "SEVEN_DAY_PROMO", label: "Whatever").isPromotional)
        XCTAssertFalse(Fixture.bucket(id: "seven_day", label: "All models").isPromotional)
    }

    // MARK: - isBonusPool and the credit field (cloud session credits spec, Package 1)

    func testACreditPoolIsABonusPoolThoughItIsNoPromo() {
        XCTAssertTrue(Fixture.cloudCredits.isCreditPool)
        XCTAssertTrue(Fixture.cloudCredits.isBonusPool)
        XCTAssertFalse(Fixture.cloudCredits.isPromotional, "money the account has, not a free bonus")
        let promo = Fixture.bucket(id: "seven_day_promotional", kind: .weekly)
        XCTAssertTrue(promo.isBonusPool)
        XCTAssertFalse(promo.isCreditPool, "a promo pool is a percentage, not dollars")
        XCTAssertFalse(Fixture.bucket(id: "seven_day", label: "All models", kind: .weekly).isBonusPool)
    }

    func testALastKnownBucketWrittenBy301DecodesWithNoCredit() throws {
        // last-known.json as 3.0.1 wrote this account's pool on 2026-10-04.
        let json = #"{"id":"iguana_necktie","utilization":92.368272,"resetsAt":"2026-11-05T07:59:00Z","label":"Iguana Necktie","kind":"other"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bucket = try decoder.decode(UsageBucket.self, from: Data(json.utf8))
        XCTAssertNil(bucket.credit)
        XCTAssertEqual(bucket.utilization, 92.368272)
        XCTAssertEqual(bucket.resetsAt, Date(timeIntervalSince1970: 1_793_865_540))
    }

    func testACreditSurvivesTheLastKnownRoundTripAndAWindowWritesNoCreditKey() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageBucket.self, from: try encoder.encode(Fixture.cloudCredits))
        XCTAssertEqual(decoded, Fixture.cloudCredits)
        let window = String(decoding: try encoder.encode(Fixture.bucket(id: "seven_day", kind: .weekly)), as: UTF8.self)
        XCTAssertFalse(window.contains("credit"), window)
    }

    // MARK: - clampedPercent

    func testPercentsAreClampedToTheBar() {
        // A server that reports 140% (over an exceeded limit) must not draw past the end
        // of the bar, and a negative must not draw backwards.
        XCTAssertEqual(Fixture.bucket(id: "x", percent: -5).clampedPercent, 0)
        XCTAssertEqual(Fixture.bucket(id: "x", percent: 140).clampedPercent, 100)
        XCTAssertEqual(Fixture.bucket(id: "x", percent: 42.5).clampedPercent, 42.5)
        // The raw value is kept as reported — only the drawing is clamped.
        XCTAssertEqual(Fixture.bucket(id: "x", percent: 140).utilization, 140)
    }

    // MARK: - extraUsageTitle

    func testTheExtraUsageTitleFollowsThePlan() {
        XCTAssertEqual(extraUsageTitle(plan: "Enterprise"), "Spend limit")
        XCTAssertEqual(extraUsageTitle(plan: "Team"), "Spend limit")
        XCTAssertEqual(extraUsageTitle(plan: "Max 20x"), "Extra usage credits")
        XCTAssertEqual(extraUsageTitle(plan: nil), "Extra usage credits")
    }

    // MARK: - isRetained

    func testAFailedServiceThatStillHasNumbersIsRetained() {
        // Antigravity with the app closed: the chip says "Not running", the bars
        // still show what it reported an hour ago.
        let at = Date(timeIntervalSince1970: 1_788_000_000)
        let service = Fixture.snapshot(
            id: "antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning,
            at: at
        )
        XCTAssertTrue(service.isRetained)
        XCTAssertEqual(service.retainedAt, at)
    }

    func testAHealthyServiceIsNeverRetained() {
        let service = Fixture.snapshot(buckets: [Fixture.bucket(id: "seven_day", percent: 55)])
        XCTAssertFalse(service.isRetained)
        XCTAssertNil(service.retainedAt, "live numbers carry no as-of stamp")
    }

    func testAFailedServiceWithNothingToShowIsNotRetained() {
        // Signed out and never polled: there is nothing to dim, so the chip is
        // the whole tile.
        let service = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)
        XCTAssertFalse(service.isRetained)
        XCTAssertNil(service.retainedAt)
    }
}
