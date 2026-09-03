import XCTest
@testable import Omelette

/// Opening the popover used to be an unconditional poll (`userInitiated: true`),
/// which skips the Retry-After backoff and the last-poll guard. A few opens in a
/// row while debugging drove the usage endpoint into 429s; this floor is the fix.
final class PopoverRefreshRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_440_000)

    func testAFreshPollIsNotRepeatedForAClick() {
        XCTAssertFalse(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: now.addingTimeInterval(-3), now: now))
        XCTAssertFalse(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: now.addingTimeInterval(-9.9), now: now))
    }

    func testAnOldEnoughPollIsRefreshed() {
        XCTAssertTrue(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: .distantPast, now: now), "first open after launch")
    }

    func testTheFloorStaysWellUnderTheTimerPeriod() {
        // The timer polls every 60 s by default; the floor must not make the
        // popover feel stale in normal use.
        XCTAssertEqual(AppState.popoverRefreshFloor, 10)
        XCTAssertLessThan(AppState.popoverRefreshFloor, 30)
    }
}
