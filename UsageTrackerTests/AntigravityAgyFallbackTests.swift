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

    // MARK: - The 45 s cache holds local answers only (ruling A1)

    /// A run that finished ten seconds after the poll that started it is shown by the
    /// next poll, inside the 45 s that a local answer would be cached for.
    func testAFinishedRunIsShownByThePollRightAfterIt() async {
        let agy = HeldAgy()
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: { try await agy.fetch() }
        )
        let first = await provider.fetch(now: t0)
        XCTAssertEqual(first.state, .notRunning)
        agy.release(.success(AgyUsageFixture.proOutput))
        await provider.settleAgyRun()

        let next = await provider.fetch(now: t0.addingTimeInterval(10))
        XCTAssertEqual(next.state, .ok)
        XCTAssertEqual(next.buckets, AgyUsageFixture.proBuckets)
    }

    /// The fifteen-minute cap holds on every poll: a reading shown at 14:50 old is not
    /// served again twenty seconds later, at 15:10.
    func testTheFifteenMinuteCapHoldsOnEveryPoll() async {
        let agyCalls = Calls()
        let provider = provider(firstRunOnly: agyCalls)
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let at1450 = await provider.fetch(now: t0.addingTimeInterval(890))
        await provider.settleAgyRun()
        XCTAssertEqual(at1450.state, .ok)

        let at1510 = await provider.fetch(now: t0.addingTimeInterval(910))
        XCTAssertEqual(at1510.state, .notRunning, "15:10 old is not shown, cached or not")
        XCTAssertEqual(agyCalls.count, 2, "no run was due at 15:10")
    }

    /// A web reading is not held for 45 s either: the app opened ten seconds after it is
    /// read at once. The web API keeps its own five-minute throttle.
    func testAWebReadingDoesNotHideTheAppOpeningAgain() async {
        let localCalls = Calls()
        let web = status(remaining: 0.38)
        let local = status(remaining: 0.9)
        let provider = AntigravityProvider(
            localFetch: {
                localCalls.count += 1
                if localCalls.count == 1 { throw AntigravityStatusProbeError.notRunning }
                return local
            },
            remoteFetch: { web }
        )
        let closed = await provider.fetch(now: t0)
        XCTAssertEqual(closed.buckets.first?.utilization ?? 0, 62, accuracy: 0.0001, "the web API's reading")

        let opened = await provider.fetch(now: t0.addingTimeInterval(10))
        XCTAssertEqual(opened.buckets.first?.utilization ?? 0, 10, accuracy: 0.0001, "the app's own reading")
        XCTAssertEqual(localCalls.count, 2)
    }

    // MARK: - No local probe while our run is in flight (ruling A2)

    /// The probe looks for any agy process (`.ideAndCLI`) and would find our own run: it
    /// could wait on that child's endpoints or report its sign-in error. While the run is
    /// in flight a poll goes straight to agy's last reading and the web API.
    func testWhileARunIsInFlightTheLocalProbeIsNotAsked() async {
        let agy = HeldAgy()
        let localCalls = Calls()
        let remoteCalls = Calls()
        let provider = AntigravityProvider(
            localFetch: {
                localCalls.count += 1
                throw AntigravityStatusProbeError.notRunning
            },
            remoteFetch: {
                remoteCalls.count += 1
                throw AntigravityRemoteFetchError.notLoggedIn
            },
            agyFetch: { try await agy.fetch() }
        )
        _ = await provider.fetch(now: t0) // the probe finds nothing; the run starts

        let during = await provider.fetch(now: t0.addingTimeInterval(301))
        XCTAssertEqual(localCalls.count, 1, "the probe was not asked while the run was in flight")
        XCTAssertEqual(remoteCalls.count, 2, "the web API was, its five minutes being up")
        XCTAssertEqual(during.state, .notRunning)
        XCTAssertEqual(during.stateMessage, "Antigravity isn't running")

        agy.release(.success(AgyUsageFixture.proOutput))
        await provider.settleAgyRun()
        let after = await provider.fetch(now: t0.addingTimeInterval(347))
        await provider.settleAgyRun()
        XCTAssertEqual(localCalls.count, 2, "asked again once the run is over")
        XCTAssertEqual(after.state, .ok)
        XCTAssertEqual(agy.callCount, 2, "no second run while the first was in flight; one once it was over")
    }

    // MARK: - A web reading older than the app's own is not shown (ruling A9)

    /// Agy's rule for the web API's cached reading: numbers from before the app opened do
    /// not cover newer ones once it closes again. The web API keeps its five-minute
    /// throttle; the older reading is only not shown (retention keeps the app's numbers).
    func testACachedWebReadingOlderThanTheAppsOwnIsNotShown() async {
        let localCalls = Calls()
        let remoteCalls = Calls()
        let local = status(remaining: 0.9)
        let web = status(remaining: 0.38)
        let provider = AntigravityProvider(
            localFetch: {
                localCalls.count += 1
                if localCalls.count == 2 { return local }
                throw AntigravityStatusProbeError.notRunning
            },
            remoteFetch: {
                remoteCalls.count += 1
                return web
            }
        )
        let closed = await provider.fetch(now: t0)
        XCTAssertEqual(closed.buckets.first?.utilization ?? 0, 62, accuracy: 0.0001, "the web API's reading")
        let open = await provider.fetch(now: t0.addingTimeInterval(46))
        XCTAssertEqual(open.buckets.first?.utilization ?? 0, 10, accuracy: 0.0001, "the app's own")

        let closedAgain = await provider.fetch(now: t0.addingTimeInterval(92))
        XCTAssertEqual(closedAgain.state, .notRunning, "the web reading from t0 is older than the app's from t0+46")
        XCTAssertEqual(remoteCalls.count, 1, "and the web API is not asked again inside its five minutes")

        let later = await provider.fetch(now: t0.addingTimeInterval(301))
        XCTAssertEqual(later.buckets.first?.utilization ?? 0, 62, accuracy: 0.0001, "a newer web reading is shown")
        XCTAssertEqual(remoteCalls.count, 2)
    }

    func testTheStartIntervalAndTheMaximumAgeAreWhatTheySay() {
        XCTAssertEqual(AntigravityProvider.agyMinInterval, 280)
        XCTAssertEqual(AntigravityProvider.agyReadingMaxAge, 900)
    }

    /// Spec § "Package 2": "the provider keeps that label for the bucket id so the local
    /// path shows the same name". The local reading here is the probe's 2026-10-16 Pro
    /// quota summary, mapped as the local path maps it.
    func testOnceAgyHasNamedArgonTheLocalPathUsesTheSameName() async {
        let output = AgyUsageFixture.proOutput
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: { output }
        )
        let before = await provider.publishedBuckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(before.map(\.label),
                       ["Gemini 5-hour", "Gemini weekly", "Gemini Argon", "Claude/GPT 5-hour", "Claude/GPT weekly"])

        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()

        let after = await provider.publishedBuckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(after.map(\.label),
                       ["Gemini 5-hour", "Gemini weekly", "Gemini 4 Argon", "Claude/GPT 5-hour", "Claude/GPT weekly"])
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.kind), before.map(\.kind))
    }

    func testTheNextAgyReadingReplacesTheNamesItRemembered() async {
        let agyCalls = Calls()
        let pro = AgyUsageFixture.proOutput
        let ultra = AgyUsageFixture.ultraOutput
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: {
                agyCalls.count += 1
                return agyCalls.count == 1 ? pro : ultra
            }
        )
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        _ = await provider.fetch(now: t0.addingTimeInterval(301))
        await provider.settleAgyRun()
        XCTAssertEqual(agyCalls.count, 2)

        let buckets = await provider.publishedBuckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(buckets.first { $0.kind == .modelSpecific }?.label, "Gemini Argon",
                       "a reading without the group drops its name")
    }

    /// Ruling A10: only a usable reading, one known window at least, changes the names. A
    /// run that answered with nothing to show keeps the names of the last one that did.
    func testAReadingWithNoKnownWindowKeepsTheNamesItRemembered() async {
        let agyCalls = Calls()
        let pro = AgyUsageFixture.proOutput
        let nothingKnown = AgyUsageFixture.output(
            groups: #"[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","reset_time":"2026-10-23T07:46:06Z"}]}]"#
        )
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn },
            agyFetch: {
                agyCalls.count += 1
                return agyCalls.count == 1 ? pro : nothingKnown
            }
        )
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        _ = await provider.fetch(now: t0.addingTimeInterval(301))
        await provider.settleAgyRun()
        XCTAssertEqual(agyCalls.count, 2)

        let buckets = await provider.publishedBuckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(buckets.first { $0.kind == .modelSpecific }?.label, "Gemini 4 Argon",
                       "a reading with no known window is no reading, for the names too")
    }
}
