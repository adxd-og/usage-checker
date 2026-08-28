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
}
