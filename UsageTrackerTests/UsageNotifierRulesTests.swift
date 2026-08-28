import XCTest
@testable import Omelette

/// The selection rule alone — the notification centre is deliberately out of reach
/// here, so what's tested is which windows are allowed to page the user.
final class UsageNotifierRulesTests: XCTestCase {
    func testModelScopedAndPromotionalWindowsNeverAlertForClaude() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", percent: 40, kind: .session),
                Fixture.bucket(id: "seven_day", percent: 55, kind: .weekly),
                Fixture.bucket(id: "seven_day_fable", percent: 97, kind: .modelSpecific),
                // Weekly, so only the promo rule keeps it out.
                Fixture.bucket(id: "seven_day_promotional", percent: 99, kind: .weekly),
            ]
        )

        let ids = UsageNotifier.watchableBuckets(for: service).map(\.id)
        XCTAssertEqual(ids, ["five_hour", "seven_day"])
        XCTAssertFalse(ids.contains("seven_day_fable"), "a model-scoped cap informs, it doesn't page")
        XCTAssertFalse(ids.contains("seven_day_promotional"), "a free bonus running dry costs nothing")
    }

    func testAServiceWithOnlyModelScopedWindowsAlertsOnThem() {
        // Gemini's Pro/Flash daily quotas ARE its limits — excluding them would mean
        // the provider could never alert at all.
        let gemini = Fixture.snapshot(
            id: "gemini",
            plan: "Gemini Pro",
            buckets: [
                Fixture.bucket(id: "gemini_pro", percent: 91, kind: .modelSpecific),
                Fixture.bucket(id: "gemini_flash", percent: 12, kind: .modelSpecific),
            ]
        )

        XCTAssertEqual(
            UsageNotifier.watchableBuckets(for: gemini).map(\.id),
            ["gemini_pro", "gemini_flash"]
        )
    }

    func testEnabledExtraUsageIsAppendedAsAWindow() {
        let service = Fixture.snapshot(
            id: "claude",
            plan: "Enterprise",
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2)
        )

        let watchable = UsageNotifier.watchableBuckets(for: service)
        XCTAssertEqual(watchable.map(\.id), ["five_hour", "extra_usage"])
        let extra = watchable[1]
        XCTAssertEqual(extra.label, "Spend limit")
        XCTAssertEqual(extra.utilization, 78.2)
        XCTAssertEqual(extra.kind, .other)
    }

    func testDisabledExtraUsageIsNotAppended() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2)
        )

        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service).map(\.id), ["five_hour"])
    }

    func testAServiceWithNothingButPromotionalPoolsNeverAlerts() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "seven_day_promotional", percent: 100, kind: .weekly)]
        )

        XCTAssertTrue(UsageNotifier.watchableBuckets(for: service).isEmpty)
    }
}
