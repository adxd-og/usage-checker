import XCTest
@testable import Omelette

/// How often Claude's OAuth usage endpoint is asked (spec 2026-11-02 Claude limits from
/// the status line, § Design › Cadence): with a status-line reading applied in the last
/// five minutes, at most every max(refresh interval, 300 s) — a tick up to five seconds
/// early counts as due (session ruling 7); without one, every tick as before; anything a
/// person asked for — the popover opening among them, on its own ten-second floor — asks
/// at once.
final class ClaudePollCadenceRulesTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// Seconds before `now`; a negative number is in the future.
    private func shouldFetch(
        _ trigger: ClaudePollCadenceRules.Trigger = .tick,
        lastFetch: TimeInterval?,
        applied: TimeInterval?,
        interval: Int = 60
    ) -> Bool {
        ClaudePollCadenceRules.shouldFetch(
            trigger: trigger,
            lastFetchAt: lastFetch.map { ago($0) },
            statusLineAppliedAt: applied.map { ago($0) },
            refreshIntervalSeconds: interval,
            now: now
        )
    }

    func testWithoutAReadingEveryTickAsks() {
        XCTAssertTrue(shouldFetch(lastFetch: 60, applied: nil))
        XCTAssertTrue(shouldFetch(lastFetch: 15, applied: nil, interval: 15))
    }

    func testAFreshReadingHoldsTheFetchForFiveMinutes() {
        XCTAssertFalse(shouldFetch(lastFetch: 60, applied: 30))
        XCTAssertFalse(shouldFetch(lastFetch: 294, applied: 30), "more than five seconds early")
        XCTAssertTrue(shouldFetch(lastFetch: 295, applied: 30), "five seconds early is due")
        XCTAssertTrue(shouldFetch(lastFetch: 300, applied: 30), "five minutes after the last fetch, it asks again")
    }

    /// Ruling 7: the tick that comes five minutes after a fetch asks, however its sleep and
    /// the work before it fell — not the sixth.
    func testTheFifthOneMinuteTickAsksEvenAHairEarly() {
        XCTAssertFalse(shouldFetch(lastFetch: 240, applied: 30), "the fourth tick holds")
        XCTAssertTrue(shouldFetch(lastFetch: 299.995, applied: 30), "the fifth asks")
        XCTAssertTrue(
            shouldFetch(lastFetch: 299.995, applied: 297, interval: 300),
            "on the five-minute setting, every tick a hair short of the interval still asks"
        )
    }

    func testASlowerIntervalOfTheUsersOwnStands() {
        XCTAssertEqual(ClaudePollCadenceRules.fetchInterval(refreshIntervalSeconds: 60), 300)
        XCTAssertEqual(ClaudePollCadenceRules.fetchInterval(refreshIntervalSeconds: 300), 300)
        XCTAssertEqual(ClaudePollCadenceRules.fetchInterval(refreshIntervalSeconds: 900), 900)
        XCTAssertFalse(shouldFetch(lastFetch: 600, applied: 30, interval: 900))
        XCTAssertFalse(shouldFetch(lastFetch: 894, applied: 30, interval: 900))
        XCTAssertTrue(shouldFetch(lastFetch: 895, applied: 30, interval: 900))
    }

    func testAReadingOlderThanFiveMinutesHoldsNothing() {
        XCTAssertFalse(shouldFetch(lastFetch: 60, applied: 300), "five minutes ago is still the last five minutes")
        XCTAssertTrue(shouldFetch(lastFetch: 60, applied: 301))
    }

    func testAnythingAskedForAsksAtOnce() {
        XCTAssertTrue(shouldFetch(.asked, lastFetch: 1, applied: 1))
    }

    /// Spec § Cadence: "The popover-open refresh still fetches (10 s floor unchanged)."
    func testThePopoverStillRefreshesOnItsOwnTenSecondFloor() {
        XCTAssertEqual(AppState.popoverRefreshFloor, 10)
        XCTAssertTrue(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: ago(10), now: now))
        XCTAssertFalse(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: ago(9), now: now))
        XCTAssertTrue(shouldFetch(.asked, lastFetch: 10, applied: 10), "and that poll asks Claude's endpoint")
    }

    func testTheFirstPollAsks() {
        XCTAssertTrue(shouldFetch(lastFetch: nil, applied: 30))
    }

    func testAClockThatMovedBackHoldsNothing() {
        XCTAssertTrue(shouldFetch(lastFetch: -60, applied: 30), "a fetch dated in the future")
        XCTAssertTrue(shouldFetch(lastFetch: 60, applied: -60), "a reading applied in the future")
    }
}
