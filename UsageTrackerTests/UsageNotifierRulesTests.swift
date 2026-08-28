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

    func testExtraUsageOnASubscriptionPlanIsCreditsNotASpendLimit() {
        let service = Fixture.snapshot(
            id: "claude",
            plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25)
        )

        let extra = UsageNotifier.watchableBuckets(for: service).last
        XCTAssertEqual(extra?.id, "extra_usage")
        XCTAssertEqual(extra?.label, "Extra usage credits")
    }

    func testAnAccountWithOnlyPromoAndScopedWindowsFallsBackToTheScopedOnes() {
        // The promo pool is excluded at both stages, so the model-scoped caps are what's
        // left — better than never alerting at all on such an account.
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "seven_day_promotional", percent: 99, kind: .weekly),
                Fixture.bucket(id: "seven_day_opus", percent: 88, kind: .modelSpecific),
                Fixture.bucket(id: "seven_day_fable", percent: 12, kind: .modelSpecific),
            ]
        )

        XCTAssertEqual(
            UsageNotifier.watchableBuckets(for: service).map(\.id),
            ["seven_day_opus", "seven_day_fable"]
        )
    }

    func testAPromoPoolIsRecognizedByItsLabelAlone() {
        // Server-side naming isn't guaranteed to carry "promo" in the key.
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", percent: 40, kind: .session),
                Fixture.bucket(id: "bonus_grant", label: "Promotional credits", percent: 99, kind: .weekly),
            ]
        )

        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service).map(\.id), ["five_hour"])
    }
}

/// The threshold rule's hysteresis. A percentage sitting on a threshold used to alert
/// again every couple of minutes as it rounded across it.
final class UsageNotifierThresholdTests: XCTestCase {
    private func outcome(_ percent: Int, lastFired: Int) -> UsageNotifier.ThresholdOutcome {
        UsageNotifier.thresholdOutcome(percent: percent, lastFired: lastFired, mid: 80, high: 95)
    }

    /// Replays a series of readings and returns the levels that actually alerted.
    private func firedLevels(_ readings: [Int]) -> [Int] {
        var lastFired = 0
        var fired: [Int] = []
        for p in readings {
            switch outcome(p, lastFired: lastFired) {
            case .fire(let level):
                fired.append(level)
                lastFired = level
            case .rearm(let level):
                lastFired = level
            case .unchanged:
                break
            }
        }
        return fired
    }

    func testHoveringOnAThresholdAlertsOnce() {
        XCTAssertEqual(firedLevels([80, 79, 80, 79, 80]), [80])
    }

    func testARealRetreatArmsTheThresholdAgain() {
        XCTAssertEqual(firedLevels([80, 70, 80]), [80, 80])
    }

    func testTheHigherThresholdAlertsOnTopOfTheLowerOne() {
        XCTAssertEqual(firedLevels([82, 96]), [80, 95])
    }

    func testFallingBackToTheLowerBandRearmsOnlyTheHigherAlert() {
        // 96 → 90 → 97: the 95% alert is worth repeating, the 80% one is not.
        XCTAssertEqual(firedLevels([96, 90, 97]), [95, 95])
    }

    func testTheEdgeOfTheRearmBandStillCounts() {
        // 3 points is the margin, so 77 is still "on" 80 and 76 is a retreat.
        XCTAssertEqual(outcome(77, lastFired: 80), .unchanged)
        XCTAssertEqual(outcome(76, lastFired: 80), .rearm(level: 0))
    }

    func testNothingHappensBelowBothThresholds() {
        XCTAssertEqual(firedLevels([10, 40, 79]), [])
    }
}

/// The daily summary's "have I already sent one today?" key.
final class UsageNotifierDayKeyTests: XCTestCase {
    private let tokyo = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }()

    /// 2026-08-27 00:30 in Tokyo — still 2026-08-26 in GMT, which is the whole point.
    private var earlyMorningInTokyo: Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 8
        c.day = 27
        c.hour = 0
        c.minute = 30
        return tokyo.date(from: c)!
    }

    func testTheKeyIsTheLocalCalendarDay() {
        // The old key rendered the local midnight as a GMT timestamp, so the string it
        // stored named the previous day.
        XCTAssertEqual(UsageNotifier.dayKey(for: earlyMorningInTokyo, calendar: tokyo), "2026-08-27")
    }

    func testAKeyMatchesTheDayItWasWrittenFor() {
        let day = earlyMorningInTokyo
        let key = UsageNotifier.dayKey(for: day, calendar: tokyo)
        XCTAssertTrue(UsageNotifier.isSameDay(storedKey: key, as: day, calendar: tokyo))
    }

    func testYesterdaysKeyDoesNotMatchToday() {
        let day = earlyMorningInTokyo
        let yesterday = day.addingTimeInterval(-24 * 3600)
        XCTAssertFalse(
            UsageNotifier.isSameDay(
                storedKey: UsageNotifier.dayKey(for: yesterday, calendar: tokyo),
                as: day,
                calendar: tokyo
            )
        )
    }

    func testTheKeyAnOlderBuildWroteIsStillUnderstood() {
        // Older builds stored `ISO8601DateFormatter().string(from: startOfDay)`.
        // Without this the upgrade would send a second summary on the day it happens.
        let day = earlyMorningInTokyo
        let startOfDay = tokyo.startOfDay(for: day)
        let legacyKey = ISO8601DateFormatter().string(from: startOfDay)

        XCTAssertNotEqual(legacyKey, UsageNotifier.dayKey(for: day, calendar: tokyo))
        XCTAssertTrue(UsageNotifier.isSameDay(storedKey: legacyKey, as: day, calendar: tokyo))
    }

    func testNothingStoredMeansNothingSent() {
        XCTAssertFalse(UsageNotifier.isSameDay(storedKey: "", as: Date(), calendar: tokyo))
        XCTAssertFalse(UsageNotifier.isSameDay(storedKey: "not a date", as: Date(), calendar: tokyo))
    }
}
