import XCTest
@testable import Omelette

/// Independent verification of `AppState.retainingLastGoodServices` and
/// `AppState.seededSnapshot`, attacking precedence and edge cases the
/// executor's own `LastKnownRetentionTests.swift` didn't spell out.
final class LastKnownRetentionVerificationTests: XCTestCase {
    private let stored = Date(timeIntervalSince1970: 1_788_200_000)

    private func entry(id: String, percent: Double, order: Int, at date: Date? = nil) -> LastKnownService {
        LastKnownService(
            from: Fixture.snapshot(
                id: id,
                displayName: id.capitalized,
                buckets: [Fixture.bucket(id: "\(id)_window", percent: percent)],
                at: date ?? stored
            ),
            order: order
        )
    }

    private func snapshot(_ services: [ServiceSnapshot], at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date ?? stored, isStale: false, lastError: nil)
    }

    // MARK: - Precedence: in-memory previous beats stored even when both have data

    func testInMemoryPreviousWinsOverStoredWhenBothHaveBuckets() throws {
        let previous = snapshot([Fixture.snapshot(
            id: "antigravity",
            buckets: [Fixture.bucket(id: "antigravity_window", percent: 71)],
            at: stored.addingTimeInterval(1200)
        )])
        let next = snapshot([Fixture.snapshot(id: "antigravity", buckets: [], state: .notRunning)])

        let merged = AppState.retainingLastGoodServices(
            previous: previous,
            next: next,
            stored: ["antigravity": entry(id: "antigravity", percent: 5, order: 0)]
        )

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 71,
                       "in-memory previous data must win over the file even when the file also has data")
        XCTAssertEqual(service.fetchedAt, stored.addingTimeInterval(1200))
    }

    // MARK: - A healthy next is never replaced, even with a favorable stored/previous entry

    func testAHealthyNextIsNeverReplacedByStoredOrPrevious() throws {
        let previous = snapshot([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 99)]
        )])
        let next = snapshot([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 3)], state: .ok
        )])

        let merged = AppState.retainingLastGoodServices(
            previous: previous, next: next, stored: ["claude": entry(id: "claude", percent: 88, order: 0)]
        )

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 3, "a healthy poll is never overwritten by old data")
        XCTAssertFalse(service.isRetained)
    }

    // MARK: - retryAfter and stateMessage always come from `next`, never from the retained source

    func testRetryAfterAndStateMessageComeFromNextNotFromTheRetainedSource() throws {
        let previous = snapshot([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 40)]
        )])
        var failing = Fixture.snapshot(id: "claude", buckets: [], state: .error, stateMessage: "429: rate limited")
        failing.retryAfter = 42
        let next = snapshot([failing])

        let merged = AppState.retainingLastGoodServices(previous: previous, next: next, stored: [:])

        let service = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(service.stateMessage, "429: rate limited")
        XCTAssertEqual(service.retryAfter, 42)
        XCTAssertEqual(service.buckets.first?.utilization, 40, "the numbers still come from the retained source")
    }

    // MARK: - seededSnapshot precise contract

    func testSeededSnapshotIsNotRunningWithNilStateMessage() throws {
        let seeded = AppState.seededSnapshot(from: ["codex": entry(id: "codex", percent: 30, order: 0)])
        let service = try XCTUnwrap(seeded.services.first)
        XCTAssertEqual(service.state, .notRunning)
        XCTAssertNil(service.stateMessage)
    }

    func testSeededSnapshotFetchedAtIsTheNewestStoredReading() {
        let seeded = AppState.seededSnapshot(from: [
            "claude": entry(id: "claude", percent: 20, order: 0, at: stored),
            "codex": entry(id: "codex", percent: 40, order: 1, at: stored.addingTimeInterval(-9000)),
            "antigravity": entry(id: "antigravity", percent: 62, order: 2, at: stored.addingTimeInterval(500)),
        ])
        XCTAssertEqual(seeded.fetchedAt, stored.addingTimeInterval(500),
                       "fetchedAt must be the newest of the stored readings, not the first or the last by order")
    }

    func testEmptyStoredDictionaryYieldsExactlyDotEmpty() {
        XCTAssertEqual(AppState.seededSnapshot(from: [:]), .empty)
    }
}
