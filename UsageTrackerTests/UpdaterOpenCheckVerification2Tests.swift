import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `Updater.shouldCheck` (item 8 of the batch brief): the two combinations the
/// executor's own tests never exercised — Sparkle's clock recent while ours is
/// overdue, and the reverse.
final class UpdaterOpenCheckVerification2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_600_000)

    func testSparkleRecentButOwnClockOverdueIsNotDue() {
        // Sparkle checked a minute ago (not due); our own last open-check was two
        // hours ago (due on its own). Both clocks must agree — Sparkle's says no.
        XCTAssertFalse(Updater.shouldCheck(
            sparkleLast: now.addingTimeInterval(-60),
            ownLast: now.addingTimeInterval(-7200),
            now: now
        ))
    }

    func testOwnClockRecentButSparkleOverdueIsNotDue() {
        // The reverse: Sparkle's own clock is stale (due on its own), but *we*
        // already opened the popover a minute ago and did not check then. Checking
        // again now would be the every-open hammering the fix exists to prevent.
        XCTAssertFalse(Updater.shouldCheck(
            sparkleLast: now.addingTimeInterval(-7200),
            ownLast: now.addingTimeInterval(-60),
            now: now
        ))
    }

    func testBothExactlyAtTheHourBoundaryAreDue() {
        XCTAssertTrue(Updater.shouldCheck(
            sparkleLast: now.addingTimeInterval(-3600),
            ownLast: now.addingTimeInterval(-3600),
            now: now
        ))
    }
}
