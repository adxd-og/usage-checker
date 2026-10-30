import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime: "last observed reset per window … One stretch
/// per limit reset seen in a live poll (deduplicated by window id + reset time; never on
/// relaunch or a retained refresh)".
final class PetResetWatchTests: XCTestCase {
    /// Monday 2026-10-26 13:48 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_793_022_480)
    private var firstReset: Date { t0.addingTimeInterval(600) }
    private var secondReset: Date { firstReset.addingTimeInterval(5 * 3_600) }
    private var afterFirst: Date { firstReset.addingTimeInterval(60) }

    private func claude(resetsAt: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 12, resetsAt: resetsAt, kind: .session),
        ], state: state, at: t0)
    }

    private func codex(resetsAt: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 5, resetsAt: resetsAt, kind: .session),
        ], at: t0)
    }

    func testTheFirstReadingOfAWindowOnlyRecordsIt() {
        var watch = PetResetWatch()
        XCTAssertEqual(watch.observe([claude(resetsAt: firstReset)], now: t0), [], "a relaunch sees no reset")
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], firstReset)
    }

    func testAWindowWhoseResetTimeMovedOnAfterItPassedHasReset() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        XCTAssertEqual(
            watch.observe([claude(resetsAt: secondReset)], now: afterFirst),
            [PetResetWatch.Reset(window: "claude/five_hour", resetAt: firstReset)]
        )
    }

    func testAResetIsReportedOnceEvenWhenTheProviderFlipsBack() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        XCTAssertEqual(watch.observe([claude(resetsAt: secondReset)], now: afterFirst).count, 1)
        XCTAssertEqual(watch.observe([claude(resetsAt: secondReset)], now: afterFirst + 60), [])
        XCTAssertEqual(watch.observe([claude(resetsAt: firstReset)], now: afterFirst + 120), [], "moved earlier")
        XCTAssertEqual(watch.observe([claude(resetsAt: secondReset)], now: afterFirst + 180), [], "the same reset again")
    }

    func testAResetTimeThatJittersBySecondsIsNoResetBeforeOrAfterItPasses() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        let jittered = firstReset.addingTimeInterval(1)
        XCTAssertEqual(watch.observe([claude(resetsAt: jittered)], now: t0 + 30), [])
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], jittered, "followed")
        XCTAssertEqual(watch.observe([claude(resetsAt: jittered)], now: afterFirst), [], "past it, the same time")
        XCTAssertEqual(
            watch.observe([claude(resetsAt: firstReset.addingTimeInterval(2))], now: afterFirst + 10), [],
            "a second's jitter after it passed"
        )
    }

    func testAResetAnnouncedJustBeforeTheOldOnePassedIsSeenOnceItHas() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        XCTAssertEqual(watch.observe([claude(resetsAt: secondReset)], now: t0 + 599), [], "1 s before the old reset")
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], firstReset, "the old time is kept until it passes")
        XCTAssertEqual(
            watch.observe([claude(resetsAt: secondReset)], now: t0 + 601),
            [PetResetWatch.Reset(window: "claude/five_hour", resetAt: firstReset)]
        )
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], secondReset)
    }

    func testARetainedRefreshIsNeitherReadNorRecorded() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        let retained = claude(resetsAt: secondReset, state: .notRunning)
        XCTAssertTrue(retained.isRetained)
        XCTAssertEqual(watch.observe([retained], now: afterFirst), [])
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], firstReset)
        XCTAssertEqual(
            watch.observe([claude(resetsAt: secondReset)], now: afterFirst + 60).count, 1,
            "the next live poll shows it"
        )
    }

    func testBonusPoolsAndWindowsWithoutAResetTimeAreNotWatched() {
        let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promotional", percent: 10, resetsAt: firstReset, kind: .weekly)
        let unknown = Fixture.bucket(id: "seven_day", label: "All models", percent: 10, kind: .weekly)
        XCTAssertEqual(unknown.resetsAt, .distantFuture)
        var watch = PetResetWatch()
        _ = watch.observe([Fixture.snapshot(id: "claude", buckets: [promo, Fixture.cloudCredits, unknown], at: t0)], now: t0)
        XCTAssertEqual(watch.lastResetAt, [:])
    }

    func testEachProvidersWindowsAreTheirOwn() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset), codex(resetsAt: firstReset)], now: t0)
        let resets = watch.observe([claude(resetsAt: secondReset), codex(resetsAt: secondReset)], now: afterFirst)
        XCTAssertEqual(resets.map(\.window), ["claude/five_hour", "codex/five_hour"])
    }

    func testAResetIsForgottenAfterEightDays() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(resetsAt: firstReset)], now: t0)
        _ = watch.observe([claude(resetsAt: secondReset)], now: afterFirst)
        XCTAssertEqual(watch.reported.count, 1)
        _ = watch.observe([], now: firstReset.addingTimeInterval(PetResetWatch.memory))
        XCTAssertEqual(watch.reported.count, 0)
    }
}
