import XCTest
@testable import Omelette

/// What the app shows after a poll. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "Whole-snapshot fallback: deleted. `next.services` is what the app shows; `isStale`
/// is set when every service failed. A service absent from `next` is never carried; a
/// previous `.ok` never overrides a new failure."
final class PollMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private var t1: Date { t0.addingTimeInterval(600) }

    private func poll(_ services: [ServiceSnapshot], at date: Date, lastError: String? = nil) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: lastError)
    }

    private func signedOutClaude(at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn, stateMessage: "Sign in", at: date)
    }

    func testAProviderSwitchedOffIsNotBroughtBack() {
        // The report's scenario: Codex the only provider with windows, Claude signed
        // out, then Codex switched off — the coordinator no longer returns it.
        let previous = poll([
            signedOutClaude(at: t0),
            Fixture.snapshot(id: "codex", plan: "Codex Plus",
                             buckets: [Fixture.bucket(id: "codex_session", percent: 40, kind: .session)], at: t0),
        ], at: t0)
        let next = poll([signedOutClaude(at: t1)], at: t1, lastError: "Sign in")

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        XCTAssertEqual(merged.services.map(\.id), ["claude"], "a provider absent from the poll is gone")
        XCTAssertFalse(merged.services.contains { $0.state == .ok })
        XCTAssertFalse(merged.hasAnyData)
    }

    func testAPreviousOkNeverStandsInForANewFailure() throws {
        let previous = poll([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)], at: t0
        )], at: t0)
        let next = poll([Fixture.snapshot(
            id: "claude", plan: nil, buckets: [], state: .error, stateMessage: "429: rate limited", at: t1
        )], at: t1, lastError: "429: rate limited")

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        let claude = try XCTUnwrap(merged.services.first)
        XCTAssertEqual(claude.state, .error, "the failure keeps its state")
        XCTAssertEqual(claude.stateMessage, "429: rate limited")
        XCTAssertEqual(claude.buckets.first?.utilization, 40, "and only its last reading, dimmed")
        XCTAssertTrue(claude.isRetained)
    }

    func testEveryServiceFailingIsStaleAndDatedByTheReading() {
        let previous = poll([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)], at: t0
        )], at: t0)
        let next = poll([Fixture.snapshot(
            id: "claude", plan: nil, buckets: [], state: .error, stateMessage: "429: rate limited", at: t1
        )], at: t1, lastError: "429: rate limited")

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, t0, "\"showing data from\" dates the numbers, not the failed attempt")
        XCTAssertEqual(merged.lastError, "429: rate limited")
    }

    func testOneLiveServiceKeepsTheSnapshotFresh() throws {
        let previous = poll([Fixture.snapshot(
            id: "antigravity", buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)], at: t0
        )], at: t0)
        let next = poll([
            Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 20, kind: .session)], at: t1),
            Fixture.snapshot(id: "antigravity", plan: nil, buckets: [], state: .notRunning, at: t1),
        ], at: t1)

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        XCTAssertFalse(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, t1)
        XCTAssertEqual(merged.services.map(\.id), ["claude", "antigravity"])
        let antigravity = try XCTUnwrap(merged.services.last)
        XCTAssertTrue(antigravity.isRetained, "per-service retention still applies")
    }

    func testAFailedPollWithNothingToKeepIsDatedByThePoll() {
        let next = poll([Fixture.snapshot(id: "codex", plan: nil, buckets: [], state: .notSignedIn, at: t1)], at: t1)

        let merged = AppState.mergingPoll(previous: .empty, next: next, stored: [:])

        XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, t1)
        XCTAssertEqual(merged.services, next.services)
    }

    func testAPollWithNoServicesIsNotStale() {
        XCTAssertFalse(AppState.mergingPoll(previous: .empty, next: poll([], at: t1)).isStale)
    }
}
