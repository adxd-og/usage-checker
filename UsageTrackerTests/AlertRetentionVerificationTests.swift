import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 8. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Alerts:
/// both loops evaluate `state == .ok` services only; `lastFiredKey` is neither re-armed
/// nor cleared for a retained service."
///
/// `UsageNotifierRetentionTests` (the executor's own file) already pins the filter with
/// session-bucket fixtures. This file drives the same rule through the extra-usage
/// (spend limit) bucket and through the exact two-step pipeline (`alertableServices`
/// then `watchableBuckets`, then the session-only filter `evaluatePacing` applies) the
/// production loops actually run, with fixtures the executor did not use.
final class AlertRetentionVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_500_000)

    private var overLimitExtraUsage: ExtraUsage {
        ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 196, utilization: 98)
    }

    func testARetainedSpendLimitNeverReachesTheThresholdPipeline() {
        // Enterprise Claude with a spend limit, now failing but carrying its last
        // reading: `isCarriedOver` true, buckets empty (retention keeps the extra-usage
        // limit through `extraUsage`, not through `buckets`).
        var retainedClaude = Fixture.snapshot(
            id: "claude", buckets: [], extraUsage: overLimitExtraUsage,
            state: .error, stateMessage: "500: internal error", at: now
        )
        retainedClaude.isCarriedOver = true
        XCTAssertTrue(retainedClaude.isRetained)

        let liveCodex = Fixture.snapshot(
            id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 20, kind: .session)], at: now
        )

        // The exact composition `evaluate(snapshot:)` runs: filter, then per-service
        // watchable buckets, then the threshold keys that would be looked up.
        let alertable = UsageNotifier.alertableServices([retainedClaude, liveCodex])
        let keys = alertable.flatMap { service in
            UsageNotifier.watchableBuckets(for: service).map { "\(service.id):\($0.id)" }
        }

        XCTAssertEqual(alertable.map(\.id), ["codex"], "the retained spend limit is not evaluated at all")
        XCTAssertEqual(keys, ["codex:codex_session"])
        XCTAssertFalse(keys.contains("claude:extra_usage"), "a 98% spend limit that is only a last reading never keys a threshold check")
    }

    func testARetainedSessionWindowNeverReachesThePacingPool() {
        // The pool `evaluatePacing` iterates: alertable services, their session
        // buckets. A retained weekly bucket is excluded twice over (state and kind),
        // a retained session bucket only needs the state filter.
        let retainedAntigravity = Fixture.snapshot(
            id: "antigravity",
            buckets: [
                Fixture.bucket(id: "antigravity_session", percent: 91,
                               resetsAt: now.addingTimeInterval(600), kind: .session),
                Fixture.bucket(id: "antigravity_weekly", percent: 40,
                               resetsAt: now.addingTimeInterval(3 * 86_400), kind: .weekly),
            ],
            state: .notRunning, stateMessage: "Not running", at: now.addingTimeInterval(-7200)
        )
        let liveClaude = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 55,
                                     resetsAt: now.addingTimeInterval(1800), kind: .session)],
            at: now
        )
        XCTAssertTrue(retainedAntigravity.isRetained)

        let pacingPool = UsageNotifier.alertableServices([retainedAntigravity, liveClaude]).flatMap { service in
            service.buckets
                .filter { $0.kind == .session && !$0.isPromotional }
                .map { "\(service.id):\($0.id)" }
        }

        XCTAssertEqual(pacingPool, ["claude:five_hour"],
                        "the frozen session window at 91% with a reset 10 minutes out never enters the pool that would fire a pace or reset alert")
    }

    func testAServiceThatJustSignedOutWithNoRetainedContentIsAlsoExcluded() {
        // Not a retention case at all — a service that never had a reading — but the
        // same `state == .ok` gate has to cover it too, since it is not `.ok` either.
        let freshlySignedOut = Fixture.snapshot(id: "grok", buckets: [], state: .notSignedIn, at: now)
        XCTAssertFalse(freshlySignedOut.isRetained)
        XCTAssertTrue(UsageNotifier.alertableServices([freshlySignedOut]).isEmpty)
    }
}
