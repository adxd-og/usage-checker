import XCTest
@testable import Omelette

/// The current window's bounds and which windows an account has: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds
/// ("The current window: `resetsAt − windowDuration` to now"), and § The tab, item 1
/// ("only the windows the account has: Codex Prolite shows Week alone").
final class LimitShareWindowTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    func testTheCurrentWeekRunsFromItsResetMinusSevenDaysToNow() {
        let weekly = Fixture.bucket(
            id: "seven_day", label: "All models", percent: 40,
            resetsAt: now.addingTimeInterval(2 * day), kind: .weekly
        )
        XCTAssertEqual(
            LimitShareRules.currentWindow(of: weekly, now: now),
            LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        )
    }

    func testTheCurrentSessionRunsFromItsResetMinusFiveHoursToNow() {
        let session = Fixture.bucket(
            id: "five_hour", label: "Current session", percent: 9,
            resetsAt: now.addingTimeInterval(hour), kind: .session
        )
        XCTAssertEqual(
            LimitShareRules.currentWindow(of: session, now: now),
            LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now)
        )
    }

    func testAReadingOlderThanItsResetEndsTheWindowAtTheReset() {
        // A retained snapshot: the window it describes reset an hour ago.
        let session = Fixture.bucket(
            id: "five_hour", percent: 9, resetsAt: now.addingTimeInterval(-hour), kind: .session
        )
        XCTAssertEqual(
            LimitShareRules.currentWindow(of: session, now: now),
            LimitWindow(start: now.addingTimeInterval(-6 * hour), end: now.addingTimeInterval(-hour))
        )
    }

    func testAWindowWithNoResetTimeHasNoBounds() {
        let unknown = Fixture.bucket(id: "five_hour", percent: 9, kind: .session)
        XCTAssertNil(LimitShareRules.currentWindow(of: unknown, now: now), "resetsAt is .distantFuture")
    }

    func testCodexProliteHasAWeekAndNoSession() {
        // Codex names its first lane `codex_session` whatever its length; Prolite's
        // lane is 10,080 minutes long.
        let weekly = Fixture.bucket(
            id: "codex_session", label: "Weekly", percent: 10,
            resetsAt: now.addingTimeInterval(day), kind: .weekly, windowLength: 10_080 * 60
        )
        let codex = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [weekly])

        XCTAssertEqual(LimitShareRules.windowKinds(of: codex), [.weekly])
        XCTAssertEqual(LimitShareRules.coreBucket(kind: .weekly, in: codex)?.id, "codex_session")
        XCTAssertNil(LimitShareRules.coreBucket(kind: .session, in: codex))
        XCTAssertEqual(
            LimitShareRules.currentWindow(of: weekly, now: now),
            LimitWindow(start: now.addingTimeInterval(-6 * day), end: now)
        )
    }

    func testClaudeMaxHasASessionAndAWeekButNoModelWindowOrCreditPool() {
        let claude = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", percent: 9, kind: .session),
            Fixture.bucket(id: "seven_day", percent: 40, kind: .weekly),
            Fixture.bucket(id: "seven_day_opus", percent: 60, kind: .modelSpecific),
            Fixture.cloudCredits,
        ])

        XCTAssertEqual(LimitShareRules.windowKinds(of: claude), [.session, .weekly])
        XCTAssertEqual(LimitShareRules.coreBucket(kind: .session, in: claude)?.id, "five_hour")
        XCTAssertEqual(LimitShareRules.coreBucket(kind: .weekly, in: claude)?.id, "seven_day")
        XCTAssertNil(LimitShareRules.coreBucket(kind: .modelSpecific, in: claude), "model-specific windows are out of scope")
    }

    func testTheWeeklyBudgetOmeletteInventsIsNotALimitWindow() {
        let budget = Fixture.bucket(
            id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget", percent: 82, kind: .weekly
        )
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [budget], weekCost: 412)

        XCTAssertEqual(LimitShareRules.windowKinds(of: api), [])
        XCTAssertNil(LimitShareRules.coreBucket(kind: .weekly, in: api))
    }
}
