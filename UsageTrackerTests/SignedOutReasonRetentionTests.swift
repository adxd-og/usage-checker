import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Sign in: why Claude is
/// signed out rides on the snapshot, and the retention that keeps a failed provider's last
/// numbers on screen (`AppState.mergingPoll`, `droppingRetained`) keeps the reason with
/// them — the way out the popover and Settings offer follows from it.
final class SignedOutReasonRetentionTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_793_100_000)
    private let now = Date(timeIntervalSince1970: 1_793_100_600)

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    private var claudeWithNumbers: ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 40, kind: .session)],
            at: earlier
        )
    }

    func testTheReasonIsOnTheSignedOutSnapshot() {
        let signedOut = ServiceSnapshot.notSignedIn(reason: .expired, message: "Expired.", at: now)
        XCTAssertEqual(signedOut.id, "claude")
        XCTAssertEqual(signedOut.state, .notSignedIn)
        XCTAssertEqual(signedOut.signedOutReason, .expired)
        XCTAssertEqual(signedOut.stateMessage, "Expired.")
    }

    func testKeptNumbersKeepTheReasonBesideThem() throws {
        let merged = AppState.mergingPoll(
            previous: poll([claudeWithNumbers], at: earlier),
            next: poll([.notSignedIn(reason: .expired, message: "Expired.", at: now)], at: now)
        )
        let claude = try XCTUnwrap(merged.services.first)
        XCTAssertTrue(claude.isRetained, "the last numbers stay, dimmed")
        XCTAssertEqual(claude.buckets.map(\.id), ["five_hour"])
        XCTAssertEqual(claude.state, .notSignedIn)
        XCTAssertEqual(claude.signedOutReason, .expired)
    }

    func testWithNothingToKeepTheReasonStillArrives() throws {
        let merged = AppState.mergingPoll(
            previous: .empty,
            next: poll([.notSignedIn(reason: .denied, message: "Permission.", at: now)], at: now)
        )
        XCTAssertEqual(try XCTUnwrap(merged.services.first).signedOutReason, .denied)
    }

    func testNumbersKeptOnDiskKeepTheReasonToo() throws {
        let merged = AppState.mergingPoll(
            previous: .empty,
            next: poll([.notSignedIn(reason: .notFound, message: "Not signed in.", at: now)], at: now),
            stored: ["claude": LastKnownService(from: claudeWithNumbers, order: 0)]
        )
        let claude = try XCTUnwrap(merged.services.first)
        XCTAssertTrue(claude.isRetained)
        XCTAssertEqual(claude.signedOutReason, .notFound)
    }

    func testForgettingTheKeptNumbersKeepsTheReason() throws {
        let merged = AppState.mergingPoll(
            previous: poll([claudeWithNumbers], at: earlier),
            next: poll([.notSignedIn(reason: .unreadable, message: "Could not parse credentials.", at: now)], at: now)
        )
        let forgotten = AppState.droppingRetained(serviceID: "claude", from: merged)
        let claude = try XCTUnwrap(forgotten.services.first)
        XCTAssertTrue(claude.buckets.isEmpty)
        XCTAssertEqual(claude.signedOutReason, .unreadable)
    }

    func testAHealthyOrSeededProviderHasNoReason() throws {
        XCTAssertNil(claudeWithNumbers.signedOutReason)
        let seeded = AppState.seededSnapshot(from: ["claude": LastKnownService(from: claudeWithNumbers, order: 0)])
        XCTAssertNil(try XCTUnwrap(seeded.services.first).signedOutReason, "nothing has been polled yet")
    }
}
