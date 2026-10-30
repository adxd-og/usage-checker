import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 Runtime ("one stretch per limit reset
/// seen in a live poll, deduplicated by window id + reset time; never on relaunch or a
/// retained refresh") and the session rulings: a reset announced before the old time passed is
/// reported once it has; jitter under a minute is no reset; each reset is reported once.
final class PetResetWatchVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_022_480)
    private var first: Date { t0.addingTimeInterval(3_600) }

    private func claude(_ resetsAt: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 5, resetsAt: resetsAt, kind: .session),
        ], state: state, at: t0)
    }

    func testAMoveOfExactlyAMinuteIsAResetAndJustUnderIsJitter() {
        var jitter = PetResetWatch()
        _ = jitter.observe([claude(first)], now: t0)
        XCTAssertEqual(jitter.observe([claude(first.addingTimeInterval(59.9))], now: first.addingTimeInterval(120)), [])
        var reset = PetResetWatch()
        _ = reset.observe([claude(first)], now: t0)
        XCTAssertEqual(
            reset.observe([claude(first.addingTimeInterval(60))], now: first.addingTimeInterval(120)).count, 1
        )
    }

    func testAPollExactlyAtTheOldResetTimeSeesTheReset() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(first)], now: t0)
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(5 * 3_600))], now: first).count, 1)
    }

    func testAnEarlyAnnouncementThatChangesAgainStillReportsTheOriginalResetOnce() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(first)], now: t0)
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(5 * 3_600))], now: first.addingTimeInterval(-120)), [])
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(6 * 3_600))], now: first.addingTimeInterval(-60)), [])
        XCTAssertEqual(watch.lastResetAt["claude/five_hour"], first, "undecided: the old time is kept")
        let found = watch.observe([claude(first.addingTimeInterval(6 * 3_600))], now: first.addingTimeInterval(30))
        XCTAssertEqual(found, [PetResetWatch.Reset(window: "claude/five_hour", resetAt: first)])
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(6 * 3_600))], now: first.addingTimeInterval(90)), [])
    }

    func testAnEarlyAnnouncementTakenBackWithinJitterIsNoReset() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(first)], now: t0)
        _ = watch.observe([claude(first.addingTimeInterval(5 * 3_600))], now: first.addingTimeInterval(-120))
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(2))], now: first.addingTimeInterval(-60)), [])
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(2))], now: first.addingTimeInterval(60)), [])
    }

    func testTwoWindowsOfOneProviderResettingInOnePollAreTwoResetsInDisplayOrder() {
        func poll(_ session: Date, _ week: Date) -> [ServiceSnapshot] {
            [Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 5, resetsAt: session, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 5, resetsAt: week, kind: .weekly),
            ], at: t0)]
        }
        var watch = PetResetWatch()
        _ = watch.observe(poll(first, first), now: t0)
        let found = watch.observe(poll(first.addingTimeInterval(5 * 3_600), first.addingTimeInterval(7 * 86_400)), now: first.addingTimeInterval(10))
        XCTAssertEqual(found.map(\.window), ["claude/five_hour", "claude/seven_day"])
    }

    func testARetainedPollHidesNoResetFromTheNextLiveOne() {
        var watch = PetResetWatch()
        _ = watch.observe([claude(first)], now: t0)
        for state in [ServiceState.notRunning, .error, .notSignedIn] {
            XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(5 * 3_600), state: state)], now: first.addingTimeInterval(60)), [], "\(state)")
        }
        XCTAssertEqual(watch.observe([claude(first.addingTimeInterval(5 * 3_600))], now: first.addingTimeInterval(120)).count, 1)
    }

    /// Three days of polls every five minutes against a five-hour window and a weekly one,
    /// with seconds of jitter on every reading, announcements up to two minutes early, and a
    /// retained poll now and then: each boundary the clock crosses is reported exactly once.
    func testEveryBoundaryCrossedIsReportedExactlyOnceThroughJitterEarlyAnnouncementsAndRetainedPolls() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let shortLength: TimeInterval = 5 * 3_600
        let longLength: TimeInterval = 7 * 86_400
        let start = t0
        func boundary(after t: Date, length: TimeInterval, offset: TimeInterval) -> Date {
            let k = floor((t.timeIntervalSince(start) - offset) / length) + 1
            return start.addingTimeInterval(offset + k * length)
        }
        var watch = PetResetWatch()
        var reported: [PetResetWatch.Reset] = []
        var t = start
        let end = start.addingTimeInterval(3 * 86_400)
        while t < end {
            let early = next() < 0.3 ? 120 * next() : 0
            let readAt = t.addingTimeInterval(early)
            let shortReset = boundary(after: readAt, length: shortLength, offset: 1_000).addingTimeInterval(next() * 10 - 5)
            let longReset = boundary(after: readAt, length: longLength, offset: 200_000).addingTimeInterval(next() * 10 - 5)
            let live = next() > 0.1
            let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 5, resetsAt: shortReset, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 5, resetsAt: longReset, kind: .weekly),
            ], state: live ? .ok : .notRunning, at: t)
            reported += watch.observe([service], now: t)
            t = t.addingTimeInterval(300)
        }
        func crossed(offset: TimeInterval, length: TimeInterval, before limit: Date) -> Int {
            var count = 0
            var boundaryAt = start.addingTimeInterval(offset)
            while boundaryAt <= limit {
                if boundaryAt > start { count += 1 }
                boundaryAt = boundaryAt.addingTimeInterval(length)
            }
            return count
        }
        // A boundary in the last two hours may not have had its live poll yet.
        for (window, offset, length) in [("claude/five_hour", 1_000.0, shortLength), ("claude/seven_day", 200_000.0, longLength)] {
            let seen = reported.filter { $0.window == window }.count
            XCTAssertGreaterThanOrEqual(seen, crossed(offset: offset, length: length, before: end.addingTimeInterval(-7_200)), window)
            XCTAssertLessThanOrEqual(seen, crossed(offset: offset, length: length, before: end), window)
        }
        XCTAssertGreaterThan(reported.filter { $0.window == "claude/five_hour" }.count, 10)
        XCTAssertEqual(Set(reported).count, reported.count, "no reset twice")
    }
}
