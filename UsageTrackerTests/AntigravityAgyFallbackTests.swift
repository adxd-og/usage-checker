import XCTest
import CodexBarCore
@testable import Omelette

/// With Antigravity closed the provider reads `agy -p /usage` in the background and shows
/// its reading before the web API (spec 2026-10-16-antigravity-argon § "Package 2", Design;
/// session ruling of 2026-10-16: a poll never waits for agy). agy is injected as the stdout
/// it would print (`AgyUsageFixture`): no test starts agy, scans for a process or opens a
/// socket. Time is a fixed epoch; `settleAgyRun()` lets a test see a finished run's reading
/// on its next poll without racing the run.
final class AntigravityAgyFallbackTests: XCTestCase {
    private let t0 = AgyUsageFixture.readAt

    /// A counter the @Sendable closures can share. The test reads it after
    /// `settleAgyRun()`, when the background run that wrote it is over.
    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    /// An agy stand-in that answers only when the test releases it, and every later call
    /// at once with the same answer. Counts the runs that reached it.
    private final class HeldAgy: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Data, Error>?
        private var answer: Result<Data, Error>?
        private var calls = 0

        func fetch() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                calls += 1
                if let answer {
                    lock.unlock()
                    continuation.resume(with: answer)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        }

        func release(_ result: Result<Data, Error>) {
            lock.lock()
            answer = result
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        /// Whether the test has released it yet.
        var isReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return answer != nil
        }
    }

    /// One Gemini 3 Pro model with `remaining` left: a per-model reading, as the web API
    /// hands it over.
    private func status(remaining: Double, plan: String? = "pro") -> AntigravityStatusSnapshot {
        AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro",
                    modelId: "gemini-3-pro",
                    remainingFraction: remaining,
                    resetTime: nil,
                    resetDescription: nil
                ),
            ],
            accountEmail: "owner@example.com",
            accountPlan: plan,
            source: .remote
        )
    }

    /// The coordinator has no per-provider deadline: a poll that waited for agy would hold
    /// every provider's update. This agy answers only when the test releases it, which it
    /// does only after the poll came back (session ruling A12: an order, not a stopwatch).
    /// The expectation's timeout is a hang guard for a broken build, not a measurement.
    func testAPollNeverWaitsForAgy() async {
        let agy = HeldAgy()
        let remoteCalls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                remoteCalls.count += 1
                throw AntigravityRemoteFetchError.notLoggedIn
            },
            agyFetch: { try await agy.fetch() }
        )
        let now = t0
        let returned = expectation(description: "the poll came back")
        let poll = Task {
            let snapshot = await provider.fetch(now: now)
            returned.fulfill()
            return snapshot
        }

        await fulfillment(of: [returned], timeout: 30)
        let agyWasStillHeld = !agy.isReleased
        agy.release(.failure(AgyUsageError.timedOut))
        let snapshot = await poll.value

        XCTAssertTrue(agyWasStillHeld, "the poll came back while agy had not answered")
        XCTAssertEqual(snapshot.state, .notRunning, "no agy reading yet: the chain goes on as today")
        XCTAssertEqual(remoteCalls.count, 1)
        await provider.settleAgyRun()
        XCTAssertEqual(agy.callCount, 1, "the poll started one run")
    }

    func testAFinishedRunsReadingIsReturnedByTheNextPoll() async {
        let agy = HeldAgy()
        let remoteCalls = Calls()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                remoteCalls.count += 1
                throw AntigravityRemoteFetchError.notLoggedIn
            },
            agyFetch: { try await agy.fetch() }
        )

        _ = await provider.fetch(now: t0)
        agy.release(.success(AgyUsageFixture.proOutput))
        await provider.settleAgyRun()
        let snapshot = await provider.fetch(now: t0.addingTimeInterval(46))

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertNil(snapshot.stateMessage)
        XCTAssertEqual(snapshot.buckets, AgyUsageFixture.proBuckets)
        XCTAssertEqual(snapshot.plan, "Antigravity", "agy prints no plan, and nothing was read before")
        XCTAssertNil(snapshot.accountLabel)
        XCTAssertEqual(snapshot.fetchedAt, t0, "stamped with the poll that started the run")
        XCTAssertEqual(remoteCalls.count, 1, "the second poll had agy's reading and left the web API alone")
    }

    func testOneRunAtATimeAndAtMostOneStartPerInterval() async {
        let agy = HeldAgy()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: { try await agy.fetch() }
        )

        _ = await provider.fetch(now: t0)
        _ = await provider.fetch(now: t0.addingTimeInterval(46)) // inside the interval
        _ = await provider.fetch(now: t0.addingTimeInterval(301)) // past it, the run still in flight
        agy.release(.failure(AgyUsageError.timedOut))
        await provider.settleAgyRun()
        XCTAssertEqual(agy.callCount, 1)

        _ = await provider.fetch(now: t0.addingTimeInterval(347)) // past it, nothing in flight
        await provider.settleAgyRun()
        XCTAssertEqual(agy.callCount, 2)
    }

    /// An agy stand-in whose first run answers with the live output and every later run
    /// fails, counted.
    private func provider(firstRunOnly agyCalls: Calls) -> AntigravityProvider {
        let output = AgyUsageFixture.proOutput
        return AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: {
                agyCalls.count += 1
                if agyCalls.count == 1 { return output }
                throw AgyUsageError.timedOut
            }
        )
    }

    /// A failed run leaves the last good reading in place until it is fifteen minutes old:
    /// 14:59 is shown, 15:01 is not.
    func testAReadingOlderThanFifteenMinutesIsNotUsed() async {
        let shownCalls = Calls()
        let shown = provider(firstRunOnly: shownCalls)
        _ = await shown.fetch(now: t0)
        await shown.settleAgyRun()
        let whileTheSecondRunFails = await shown.fetch(now: t0.addingTimeInterval(345))
        await shown.settleAgyRun()
        XCTAssertEqual(whileTheSecondRunFails.state, .ok)
        XCTAssertEqual(whileTheSecondRunFails.fetchedAt, t0)
        let at1459 = await shown.fetch(now: t0.addingTimeInterval(899))
        await shown.settleAgyRun()
        XCTAssertEqual(at1459.state, .ok, "14:59 old is still shown")
        XCTAssertEqual(at1459.fetchedAt, t0)
        XCTAssertEqual(shownCalls.count, 3)

        let droppedCalls = Calls()
        let dropped = provider(firstRunOnly: droppedCalls)
        _ = await dropped.fetch(now: t0)
        await dropped.settleAgyRun()
        let at1501 = await dropped.fetch(now: t0.addingTimeInterval(901))
        await dropped.settleAgyRun()
        XCTAssertEqual(at1501.state, .notRunning, "15:01 old is not")
        XCTAssertEqual(at1501.stateMessage, "Antigravity isn't running")
        XCTAssertEqual(droppedCalls.count, 2)
    }

    /// With the five-minute poll setting a timer that fires a little early must not skip a
    /// run: 279 s after the last start is too soon, 285 s is not.
    func testAPollAFewSecondsShortOfFiveMinutesStillStartsARun() async {
        let earlyCalls = Calls()
        let early = provider(firstRunOnly: earlyCalls)
        _ = await early.fetch(now: t0)
        await early.settleAgyRun()
        _ = await early.fetch(now: t0.addingTimeInterval(279))
        await early.settleAgyRun()
        XCTAssertEqual(earlyCalls.count, 1)

        let jitterCalls = Calls()
        let jitter = provider(firstRunOnly: jitterCalls)
        _ = await jitter.fetch(now: t0)
        await jitter.settleAgyRun()
        _ = await jitter.fetch(now: t0.addingTimeInterval(285))
        await jitter.settleAgyRun()
        XCTAssertEqual(jitterCalls.count, 2)
    }

    func testAnAgyFailureLeavesTheWebAPIToAnswerAsToday() async {
        let remoteCalls = Calls()
        let ok = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: {
                remoteCalls.count += 1
                return ok
            },
            agyFetch: { throw AgyUsageError.timedOut }
        )

        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let snapshot = await provider.fetch(now: t0.addingTimeInterval(46))

        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(snapshot.buckets.first?.id, "antigravity_gemini", "the web API's per-model reading")
        XCTAssertEqual(remoteCalls.count, 1, "the web API keeps its own five-minute cache")
    }

    /// No agy, a locked keychain, the deadline, a failed run, a status other than SUCCESS,
    /// output that is no answer: all the quiet grey state, never the red chip.
    func testEveryAgyFailureIsTheQuietNotRunningState() async {
        let failures: [AgyUsageError] = [
            .notInstalled, .keychainLocked, .keychainStateUnknown, .timedOut, .exitStatus(1),
            .launchFailed("denied"), .outputTooLarge,
        ]
        for failure in failures {
            let provider = AntigravityProvider(
                localFetch: { throw AntigravityStatusProbeError.notRunning },
                remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
                agyFetch: { throw failure }
            )
            _ = await provider.fetch(now: t0)
            await provider.settleAgyRun()
            let snapshot = await provider.fetch(now: t0.addingTimeInterval(46))
            XCTAssertEqual(snapshot.state, .notRunning, "\(failure)")
            XCTAssertEqual(snapshot.stateMessage, "Antigravity isn't running", "\(failure)")
            XCTAssertTrue(snapshot.buckets.isEmpty, "\(failure)")
        }
        for output in [AgyUsageFixture.signedOutOutput, Data("zsh: killed".utf8)] {
            let provider = AntigravityProvider(
                localFetch: { throw AntigravityStatusProbeError.notRunning },
                remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
                agyFetch: { output }
            )
            _ = await provider.fetch(now: t0)
            await provider.settleAgyRun()
            let snapshot = await provider.fetch(now: t0.addingTimeInterval(46))
            XCTAssertEqual(snapshot.state, .notRunning)
            XCTAssertEqual(snapshot.stateMessage, "Antigravity isn't running")
        }
    }

    func testAReachableAppNeverRunsAgy() async {
        let agyCalls = Calls()
        let ok = status(remaining: 0.38)
        let output = AgyUsageFixture.proOutput
        let provider = AntigravityProvider(
            localFetch: { ok },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: {
                agyCalls.count += 1
                return output
            }
        )
        let snapshot = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertEqual(agyCalls.count, 0, "the local probe is free; agy is a child process")
    }

    func testAnErrorThatIsNotNotRunningNeverRunsAgy() async {
        let agyCalls = Calls()
        let output = AgyUsageFixture.proOutput
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.authenticationRequired },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: {
                agyCalls.count += 1
                return output
            }
        )
        let snapshot = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(agyCalls.count, 0)
    }

    func testAnAgyReadingWithNoKnownWindowIsNoReading() async {
        let output = AgyUsageFixture.output(
            groups: #"[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","reset_time":"2026-10-23T07:46:06Z"}]}]"#
        )
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: { output }
        )
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let snapshot = await provider.fetch(now: t0.addingTimeInterval(46))
        XCTAssertEqual(snapshot.state, .notRunning, "no row is no reading")
    }

    /// The app opened after agy's reading and closed again: its own newer numbers, now
    /// retained, beat agy's older ones.
    func testALocalReadingSupersedesAnEarlierAgyReading() async {
        let localCalls = Calls()
        let ok = status(remaining: 0.38)
        let output = AgyUsageFixture.proOutput
        let provider = AntigravityProvider(
            localFetch: {
                localCalls.count += 1
                if localCalls.count == 2 { return ok }
                throw AntigravityStatusProbeError.notRunning
            },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: { output }
        )

        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let open = await provider.fetch(now: t0.addingTimeInterval(46))
        XCTAssertEqual(open.buckets.first?.id, "antigravity_gemini", "the app's own reading")

        let closedAgain = await provider.fetch(now: t0.addingTimeInterval(92))
        await provider.settleAgyRun()
        XCTAssertEqual(closedAgain.state, .notRunning, "agy's reading from t0 is older than the app's from t0+46")
    }

    func testTheStartIntervalAndTheMaximumAgeAreWhatTheySay() {
        XCTAssertEqual(AntigravityProvider.agyMinInterval, 280)
        XCTAssertEqual(AntigravityProvider.agyReadingMaxAge, 900)
    }
}
