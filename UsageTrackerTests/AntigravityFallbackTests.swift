import XCTest
import CodexBarCore
@testable import Omelette

/// Antigravity's quotas live on Google's servers, not only in the local language
/// server — so a closed app is no reason to show "Not running". Both fetches are
/// injected: no port scan, no network, no OAuth file.
final class AntigravityFallbackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)

    /// A counter the @Sendable closures can share. The test target checks
    /// concurrency minimally and the whole test runs on one thread.
    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    /// One Gemini Pro model with 38% left → a "Gemini models" window at 62% used.
    private func status(remaining: Double, plan: String? = "pro") -> AntigravityStatusSnapshot {
        AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro",
                    modelId: "gemini-3-pro",
                    remainingFraction: remaining,
                    resetTime: nil,
                    resetDescription: nil
                )
            ],
            accountEmail: "owner@example.com",
            accountPlan: plan,
            source: .remote
        )
    }

    func testALocalReadingNeverTouchesTheWebAPI() async {
        let remoteCalls = Calls()
        // AntigravityStatusSnapshot is Sendable; the test case itself is not, so the
        // fixture is built here and the @Sendable closures capture the value.
        let ok = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: { ok },
            remoteFetch: {
                remoteCalls.count += 1
                throw AntigravityRemoteFetchError.notLoggedIn
            }
        )

        let snapshot = await provider.fetch(now: t0)

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.buckets.first?.id, "antigravity_gemini")
        XCTAssertEqual(remoteCalls.count, 0, "the local probe is free; the web API is not")
    }

    func testAClosedAppFallsBackToTheWebAPI() async {
        let ok = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { ok }
        )

        let snapshot = await provider.fetch(now: t0)

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertNil(snapshot.stateMessage)
        XCTAssertEqual(snapshot.plan, "Antigravity Pro")
        XCTAssertEqual(snapshot.accountLabel, "owner@example.com")
        XCTAssertEqual(snapshot.buckets.first?.id, "antigravity_gemini")
        XCTAssertEqual(snapshot.buckets.first?.utilization ?? 0, 62, accuracy: 0.0001)
    }

    func testNotLoggedInOnTheWebLeavesTheQuietNotRunningState() async {
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn }
        )

        let snapshot = await provider.fetch(now: t0)

        XCTAssertEqual(snapshot.state, .notRunning)
        XCTAssertEqual(snapshot.stateMessage, "Antigravity isn't running")
        XCTAssertTrue(snapshot.buckets.isEmpty, "retention, not this provider, decides what stays on screen")
    }

    func testAServerThatIsThereButNotAnsweringIsNotRunningNotAnError() async {
        // A lingering Antigravity process with no language server behind it: the probe
        // reports a missing CSRF token, an undetectable port or a timeout. That is the
        // grey "Not running" chip (and a web call), never the red one.
        let ok = status(remaining: 0.38)
        for probeError: AntigravityStatusProbeError in [
            .missingCSRFToken, .portDetectionFailed("no port"), .timedOut,
        ] {
            let remoteCalls = Calls()
            let provider = AntigravityProvider(
                localFetch: { throw probeError },
                remoteFetch: {
                    remoteCalls.count += 1
                    return ok
                }
            )
            let snapshot = await provider.fetch(now: t0)
            XCTAssertEqual(snapshot.state, .ok, "\(probeError) should have fallen back to the web reading")
            XCTAssertEqual(remoteCalls.count, 1, "\(probeError) should have asked the web API once")
        }
        XCTAssertFalse(AntigravityProvider.isUnreachable(AntigravityStatusProbeError.apiError("nope")))
        XCTAssertFalse(AntigravityProvider.isUnreachable(AntigravityStatusProbeError.accountMismatch(expected: "a", found: "b")))
        XCTAssertTrue(AntigravityProvider.isUnreachable(URLError(.cannotConnectToHost)),
                      "a localhost port with nobody behind it is the app having quit")
        XCTAssertTrue(AntigravityProvider.isUnreachable(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))))
        XCTAssertFalse(AntigravityProvider.isUnreachable(NSError(domain: "SomethingElse", code: 1)))
    }

    func testATransportFailureOnLocalhostFallsBackToTheWebAPI() async {
        let ok = status(remaining: 0.38)
        let remoteCalls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw URLError(.cannotConnectToHost) },
            remoteFetch: {
                remoteCalls.count += 1
                return ok
            }
        )
        let snapshot = await provider.fetch(now: t0)
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(remoteCalls.count, 1)
    }

    func testAnErrorThatIsNotNotRunningNeverReachesTheWebAPI() async {
        let remoteCalls = Calls()
        let ok = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.authenticationRequired },
            remoteFetch: {
                remoteCalls.count += 1
                return ok
            }
        )

        let snapshot = await provider.fetch(now: t0)

        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(remoteCalls.count, 0, "a signed-out CLI is a different problem, and the web API can't fix it")
    }

    func testTheWebAPIIsAskedAtMostEveryFiveMinutes() async {
        let remoteCalls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                remoteCalls.count += 1
                throw AntigravityRemoteFetchError.apiError("503")
            }
        )

        _ = await provider.fetch(now: t0)
        XCTAssertEqual(remoteCalls.count, 1)

        // Past the 45 s local cache, well inside the remote one.
        _ = await provider.fetch(now: t0.addingTimeInterval(46))
        XCTAssertEqual(remoteCalls.count, 1, "a failure stands for five minutes")

        _ = await provider.fetch(now: t0.addingTimeInterval(301))
        XCTAssertEqual(remoteCalls.count, 2)
    }

    func testASuccessfulWebReadingStandsUntilTheIntervalIsUp() async {
        let remoteCalls = Calls()
        let ok = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                remoteCalls.count += 1
                if remoteCalls.count == 1 { return ok }
                throw AntigravityRemoteFetchError.apiError("503")
            }
        )

        let first = await provider.fetch(now: t0)
        XCTAssertEqual(first.state, .ok)
        // Without a cached remote result the tile would flip to "Not running" 45 s
        // after a perfectly good web reading.
        let cached = await provider.fetch(now: t0.addingTimeInterval(46))
        XCTAssertEqual(cached.state, .ok)
        XCTAssertEqual(remoteCalls.count, 1)

        let expired = await provider.fetch(now: t0.addingTimeInterval(301))
        XCTAssertEqual(expired.state, .notRunning)
        XCTAssertEqual(remoteCalls.count, 2)
    }

    func testTheFiveMinuteIntervalIsWhatItSays() {
        XCTAssertEqual(AntigravityProvider.remoteMinInterval, 300)
    }
}
