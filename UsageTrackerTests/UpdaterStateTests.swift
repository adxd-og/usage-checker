import XCTest
@testable import Omelette

/// Sparkle's stand-in: the two KVO-compliant properties `Updater` mirrors, with the
/// names and types `SPUUpdater` gives them. `Updater.shared` is never touched here —
/// creating it would start Sparkle.
@MainActor
private final class FakeSparkleUpdater: NSObject {
    @objc dynamic var canCheckForUpdates = false
    @objc dynamic var lastUpdateCheckDate: Date?
}

@MainActor
private final class Received {
    var canCheck: [Bool] = []
    var lastCheck: [Date?] = []
}

/// Settings → Updates redraws when Sparkle changes, not at the next poll. Before this,
/// "Last check" kept the previous time after "Check for updates now". Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "`Updater` publishes `canCheckForUpdates` and `lastUpdateCheckDate` via KVO on
/// Sparkle's updater; … `lastCheckText(_:locale:timeZone:)` rule"; report D § 7.
final class UpdaterStateTests: XCTestCase {
    /// 2026-09-24 14:15 UTC.
    private let checkedAt = Date(timeIntervalSince1970: 1_790_259_300)
    /// 2026-09-24 20:15 UTC.
    private let checkedLate = Date(timeIntervalSince1970: 1_790_280_900)
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")

    @MainActor
    private func mirror(_ fake: FakeSparkleUpdater, into received: Received) -> [NSKeyValueObservation] {
        Updater.mirrorState(
            of: fake,
            canCheck: \.canCheckForUpdates,
            lastCheck: \.lastUpdateCheckDate,
            onCanCheck: { received.canCheck.append($0) },
            onLastCheck: { received.lastCheck.append($0) }
        )
    }

    // MARK: - The KVO mirror

    @MainActor
    func testTheCurrentValuesArriveAsSoonAsTheMirrorIsSetUp() {
        let fake = FakeSparkleUpdater()
        fake.canCheckForUpdates = true
        fake.lastUpdateCheckDate = checkedAt
        let received = Received()
        let observations = mirror(fake, into: received)
        XCTAssertEqual(received.canCheck, [true])
        XCTAssertEqual(received.lastCheck, [checkedAt])
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testAFinishedCheckReachesSettingsAtOnce() {
        let fake = FakeSparkleUpdater()
        let received = Received()
        let observations = mirror(fake, into: received)
        fake.lastUpdateCheckDate = checkedAt
        XCTAssertEqual(received.lastCheck, [nil, checkedAt])
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testTheCheckButtonFollowsSparkleBothWays() {
        let fake = FakeSparkleUpdater()
        let received = Received()
        let observations = mirror(fake, into: received)
        fake.canCheckForUpdates = true
        fake.canCheckForUpdates = false
        XCTAssertEqual(received.canCheck, [false, true, false])
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testAClearedDateArrivesAsNil() {
        let fake = FakeSparkleUpdater()
        let received = Received()
        let observations = mirror(fake, into: received)
        fake.lastUpdateCheckDate = checkedAt
        fake.lastUpdateCheckDate = nil
        XCTAssertEqual(received.lastCheck, [nil, checkedAt, nil])
        withExtendedLifetime(observations) {}
    }

    @MainActor
    func testNothingArrivesOnceTheObservationsAreInvalidated() {
        let fake = FakeSparkleUpdater()
        let received = Received()
        mirror(fake, into: received).forEach { $0.invalidate() }
        fake.canCheckForUpdates = true
        fake.lastUpdateCheckDate = checkedAt
        XCTAssertEqual(received.canCheck, [false])
        XCTAssertEqual(received.lastCheck, [nil])
    }

    // MARK: - The "Last check" line

    func testNoCheckYetShowsNothing() {
        // Sparkle stamps the date only when a check completes.
        XCTAssertNil(Updater.lastCheckText(nil, locale: gb, timeZone: utc))
    }

    func testALastCheckReadsAsDayAndTime() {
        XCTAssertEqual(Updater.lastCheckText(checkedAt, locale: gb, timeZone: utc), "Last check: 24 Sep 2026, 14:15")
    }

    func testTheClockIsTheUsersOwn() {
        XCTAssertEqual(
            Updater.lastCheckText(checkedAt, locale: gb, timeZone: TimeZone(identifier: "Asia/Tokyo")!),
            "Last check: 24 Sep 2026, 23:15"
        )
        XCTAssertEqual(
            Updater.lastCheckText(checkedLate, locale: gb, timeZone: TimeZone(identifier: "America/Los_Angeles")!),
            "Last check: 24 Sep 2026, 13:15"
        )
    }

    func testTheDayIsTheUsersOwnToo() {
        // Kiritimati is UTC+14: 20:15 UTC is already the next morning there.
        XCTAssertEqual(
            Updater.lastCheckText(checkedLate, locale: gb, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!),
            "Last check: 25 Sep 2026, 10:15"
        )
    }

    func testAnAmericanLocaleGetsItsOwnOrderAndClock() {
        let text = Updater.lastCheckText(checkedAt, locale: Locale(identifier: "en_US"), timeZone: utc) ?? ""
        XCTAssertTrue(text.hasPrefix("Last check: Sep 24, 2026, 2:15"), text)
        XCTAssertTrue(text.hasSuffix("PM"), text)
    }
}
