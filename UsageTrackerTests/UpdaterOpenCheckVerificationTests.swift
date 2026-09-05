import XCTest
@testable import Omelette

/// Independent verification of `Updater.isDue`, pinning the exact minute-boundary
/// cases from the verification brief (nil, 59 min, 60 min, 61 min) rather than the
/// second-based offsets the executor's own `UpdaterOpenCheckTests.swift` used.
///
/// `checkInBackgroundIfDue` itself gates on `automaticallyChecksForUpdates` and
/// `canCheckForUpdates`, both of which read straight through to a live
/// `SPUStandardUpdaterController` (`UsageTracker/Services/Updater.swift:29,37`) with
/// no injection point — exercising it would start real Sparkle machinery, which the
/// no-network-no-real-process-probes constraint rules out. That gating is verified
/// by reading, not by a test here.
final class UpdaterOpenCheckVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_500_000)

    func testNilLastCheckIsAlwaysDue() {
        XCTAssertTrue(Updater.isDue(lastCheck: nil, now: now))
    }

    func testFiftyNineMinutesIsNotYetDue() {
        XCTAssertFalse(Updater.isDue(lastCheck: now.addingTimeInterval(-59 * 60), now: now))
    }

    func testSixtyMinutesIsDue() {
        XCTAssertTrue(Updater.isDue(lastCheck: now.addingTimeInterval(-60 * 60), now: now))
    }

    func testSixtyOneMinutesIsDue() {
        XCTAssertTrue(Updater.isDue(lastCheck: now.addingTimeInterval(-61 * 60), now: now))
    }
}
