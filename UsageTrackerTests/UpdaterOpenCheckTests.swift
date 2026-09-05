import XCTest
@testable import Omelette

/// Opening the dashboard or the popover is a good moment to look for an update.
/// Doing it on *every* open is not — the popover is opened dozens of times a day.
/// Only the rule is tested: touching `Updater.shared` would start Sparkle.
final class UpdaterOpenCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_440_000)

    func testTheFirstOpenAlwaysChecks() {
        XCTAssertTrue(Updater.isDue(lastCheck: nil, now: now))
    }

    func testARecentCheckIsNotRepeated() {
        XCTAssertFalse(Updater.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(Updater.isDue(lastCheck: now.addingTimeInterval(-3599), now: now))
    }

    func testAnHourOldCheckIsDue() {
        XCTAssertTrue(Updater.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(Updater.isDue(lastCheck: now.addingTimeInterval(-86400), now: now))
    }

    func testAClockThatJumpedBackwardsDoesNotHammerTheFeed() {
        // lastCheck in the future: wait it out rather than checking on every open.
        XCTAssertFalse(Updater.isDue(lastCheck: now.addingTimeInterval(600), now: now))
    }

    func testTheIntervalIsAnHour() {
        XCTAssertEqual(Updater.openCheckInterval, 3600)
    }
}
