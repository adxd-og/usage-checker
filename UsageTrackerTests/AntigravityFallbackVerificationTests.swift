import XCTest
import CodexBarCore
@testable import Omelette

/// Independent verification of `AntigravityProvider`'s two throttles, pinning the
/// exact boundaries (`<` vs `<=`) rather than the interior points the executor's
/// own `AntigravityFallbackTests.swift` already checked.
final class AntigravityFallbackVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_050_000)

    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    private func status(remaining: Double, plan: String? = "pro") -> AntigravityStatusSnapshot {
        AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro", modelId: "gemini-3-pro",
                    remainingFraction: remaining, resetTime: nil, resetDescription: nil
                ),
            ],
            accountEmail: "owner@example.com", accountPlan: plan, source: .remote
        )
    }

    // MARK: - Local 45 s cache: exact boundary

    func testTheLocalCacheBoundaryIsExclusive() async {
        let calls = Calls()
        let ok = status(remaining: 0.5)
        let provider = AntigravityProvider(
            localFetch: {
                calls.count += 1
                return ok
            },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn }
        )

        _ = await provider.fetch(now: t0)
        XCTAssertEqual(calls.count, 1)

        // Just under 45s: still cached.
        _ = await provider.fetch(now: t0.addingTimeInterval(44.9))
        XCTAssertEqual(calls.count, 1, "44.9s must still be within the 45s local cache")

        // Exactly 45s: the cache's own comparison is `<`, so this must refetch.
        _ = await provider.fetch(now: t0.addingTimeInterval(45))
        XCTAssertEqual(calls.count, 2, "45.0s should no longer be cached")
    }

    // MARK: - Remote 5-minute cache: exact boundary, for both outcomes

    // Each boundary gets its own provider with exactly two calls (t0, t0+delta):
    // a three-call version would let the *local* 45s cache's own sliding anchor
    // (it resets to whatever `now` the previous call used) mask the remote-cache
    // boundary being tested, so the two throttles are isolated by construction.

    func testARemoteFailureIsStillCachedAt299Seconds() async {
        let calls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                calls.count += 1
                throw AntigravityRemoteFetchError.apiError("503")
            }
        )

        _ = await provider.fetch(now: t0)
        XCTAssertEqual(calls.count, 1)

        _ = await provider.fetch(now: t0.addingTimeInterval(299))
        XCTAssertEqual(calls.count, 1, "a cached failure should still stand at 299s")
    }

    func testARemoteFailureCacheExpiresAt300Seconds() async {
        let calls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                calls.count += 1
                throw AntigravityRemoteFetchError.apiError("503")
            }
        )

        _ = await provider.fetch(now: t0)
        XCTAssertEqual(calls.count, 1)

        _ = await provider.fetch(now: t0.addingTimeInterval(300))
        XCTAssertEqual(calls.count, 2, "300s is the documented interval and must trigger a fresh attempt")
    }

    func testARemoteSuccessIsStillCachedAt299Seconds() async {
        let calls = Calls()
        let ok = status(remaining: 0.5)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                calls.count += 1
                return ok
            }
        )

        let first = await provider.fetch(now: t0)
        XCTAssertEqual(first.state, .ok)

        let stillCached = await provider.fetch(now: t0.addingTimeInterval(299))
        XCTAssertEqual(stillCached.state, .ok)
        XCTAssertEqual(calls.count, 1, "a cached success should still stand at 299s")
    }

    func testARemoteSuccessCacheExpiresAt300Seconds() async {
        let calls = Calls()
        let ok = status(remaining: 0.5)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                calls.count += 1
                return ok
            }
        )

        let first = await provider.fetch(now: t0)
        XCTAssertEqual(first.state, .ok)

        let refetched = await provider.fetch(now: t0.addingTimeInterval(300))
        XCTAssertEqual(refetched.state, .ok)
        XCTAssertEqual(calls.count, 2, "300s should trigger a fresh remote attempt even though the cached result was good")
    }

    // MARK: - The local error message survives through to the snapshot

    func testANonNotRunningLocalErrorCarriesItsOwnMessage() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "custom probe failure" }
        }
        let provider = AntigravityProvider(
            localFetch: { throw Boom() },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn }
        )

        let snapshot = await provider.fetch(now: t0)
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(snapshot.stateMessage, "custom probe failure")
    }
}
