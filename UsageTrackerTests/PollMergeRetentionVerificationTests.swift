import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 4 (and its interaction
/// with item 7). Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design,
/// Retention — "Whole-snapshot fallback: deleted. `next.services` is what the app
/// shows; `isStale` is set when every service failed. A service absent from `next` is
/// never carried; a previous `.ok` never overrides a new failure." And: "`isStale` says
/// every service failed. `fetchedAt` is then the newest retained reading."
///
/// The executor's `PollMergeTests` covers single-service chains and the pure
/// "switched off" / "every service failed" cases. This file drives a mix the executor
/// did not: some failed services retained, others failed with nothing ever carried
/// over, in the same poll — and a three-poll chain of consecutive failures.
final class PollMergeRetentionVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private var t1: Date { t0.addingTimeInterval(600) }
    private var t2: Date { t0.addingTimeInterval(1200) }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    func testFetchedAtIgnoresAServiceThatWasNeverRetainedWhenEverythingFails() {
        // Claude never reported anything this session (signed out from launch);
        // Antigravity was healthy at t0 and is now failing. Both fail this poll, so
        // the merged snapshot is stale — but "showing data from …" has to date the one
        // reading that exists, not average in a service with no reading at all.
        let previous = poll([
            Fixture.snapshot(id: "claude", buckets: [], state: .notSignedIn, at: t0),
            Fixture.snapshot(id: "antigravity", buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 60)], at: t0),
        ], at: t0)
        let next = poll([
            Fixture.snapshot(id: "claude", buckets: [], state: .notSignedIn, at: t1),
            Fixture.snapshot(id: "antigravity", buckets: [], state: .notRunning, at: t1),
        ], at: t1)

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, t0, "dated by Antigravity's last real reading, not the failed attempt time, and not confused by Claude having no reading to contribute")
        let claude = merged.services.first { $0.id == "claude" }
        XCTAssertEqual(claude?.retainedAt, nil, "nothing to carry, so nothing to date by")
    }

    func testAThirdConsecutiveFailureKeepsTheOriginalReadingNotTheIntermediateOne() {
        // Poll 1: Codex healthy at 40%. Poll 2: fails, carries 40% from poll 1. Poll 3:
        // fails again — the reading has to still be 40% from t0, not silently reset or
        // drift, and `fetchedAt` still dates back to the original good poll.
        let good = poll([Fixture.snapshot(
            id: "codex", plan: "Codex Plus",
            buckets: [Fixture.bucket(id: "codex_session", percent: 40, kind: .session)], at: t0
        )], at: t0)
        let firstFailure = poll([Fixture.snapshot(
            id: "codex", plan: nil, buckets: [], state: .error, stateMessage: "500", at: t1
        )], at: t1)
        let afterFirst = AppState.mergingPoll(previous: good, next: firstFailure, stored: [:])

        let secondFailure = poll([Fixture.snapshot(
            id: "codex", plan: nil, buckets: [], state: .error, stateMessage: "500", at: t2
        )], at: t2)
        let afterSecond = AppState.mergingPoll(previous: afterFirst, next: secondFailure, stored: [:])

        let codex = try? XCTUnwrap(afterSecond.services.first)
        XCTAssertEqual(codex?.buckets.first?.utilization, 40, "still the original reading, not lost after the second failure")
        XCTAssertEqual(codex?.retainedAt, t0, "dated by when the numbers were last true, not by either failed attempt")
        XCTAssertTrue(afterSecond.isStale)
        XCTAssertEqual(afterSecond.fetchedAt, t0)
    }

    func testAStoredReadingWithNoSessionHistoryStillDatesAFullyFailedFirstPoll() {
        // A relaunch: nothing in `previous` this session yet, but the file remembers
        // Grok from before the app closed. The very first poll fails outright.
        let storedAt = t0.addingTimeInterval(-3600)
        let stored = ["grok": LastKnownService(
            from: Fixture.snapshot(id: "grok", displayName: "Grok", buckets: [], weekCost: 12.5, at: storedAt),
            order: 0
        )]
        let next = poll([Fixture.snapshot(
            id: "grok", displayName: "Grok", plan: nil, buckets: [],
            state: .error, stateMessage: "500", at: t0
        )], at: t0)

        let merged = AppState.mergingPoll(previous: .empty, next: next, stored: stored)

        XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, storedAt, "dated by the stored reading, the only true one available")
        XCTAssertEqual(merged.services.first?.weekCost, 12.5)
        XCTAssertTrue(merged.services.first?.isRetained ?? false)
    }

    func testASwitchedOffProviderStaysGoneAcrossASubsequentFailedPollOfAnother() {
        // Two providers; one is switched off (absent from `next`) while the other
        // fails this same poll. The absent one must not resurface even though the
        // poll as a whole is now "every reporting service failed".
        let previous = poll([
            Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 10, kind: .session)], at: t0),
            Fixture.snapshot(id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 20, kind: .session)], at: t0),
        ], at: t0)
        // Codex switched off (coordinator drops it entirely); Claude fails this poll.
        let next = poll([Fixture.snapshot(
            id: "claude", plan: nil, buckets: [], state: .error, stateMessage: "429", at: t1
        )], at: t1)

        let merged = AppState.mergingPoll(previous: previous, next: next, stored: [:])

        XCTAssertEqual(merged.services.map(\.id), ["claude"], "codex stays gone, not brought back by the other service's retention")
        XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.fetchedAt, t0)
    }
}
