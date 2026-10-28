import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, Attempt state is shared:
/// the provider is built anew every poll, so one actor holds the last attempt and the pending
/// sign-in — at most one start of Claude Code every five minutes, one at a time, and none while
/// a sign-in launched from the button is under ten minutes old and has not produced a token.
/// The clock is the `now` each call is handed.
final class ClaudeRenewalGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_100_000)

    private var fresh: ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"fresh","refreshToken":"r","expiresAt":1793128800000,
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    private actor Starts {
        private(set) var count = 0
        func add() { count += 1 }
    }

    func testTheFirstAttemptRuns() async {
        let gate = ClaudeRenewalGate()
        let starts = Starts()
        let fresh = self.fresh
        let outcome = await gate.attempt(now: t0) { await starts.add(); return fresh }
        XCTAssertEqual(outcome, .renewed(fresh))
        let count = await starts.count
        XCTAssertEqual(count, 1)
    }

    func testRepeatedFailingPollsStartClaudeCodeOncePerFiveMinutes() async {
        let gate = ClaudeRenewalGate()
        let starts = Starts()
        let fail: @Sendable () async -> ClaudeCredentials.OAuth? = { await starts.add(); return nil }

        let first = await gate.attempt(now: t0, fail)
        let minuteLater = await gate.attempt(now: t0.addingTimeInterval(60), fail)
        let justBefore = await gate.attempt(now: t0.addingTimeInterval(299), fail)
        let fiveMinutes = await gate.attempt(now: t0.addingTimeInterval(300), fail)

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(minuteLater, .refused(.coolingDown))
        XCTAssertEqual(justBefore, .refused(.coolingDown))
        XCTAssertEqual(fiveMinutes, .failed)
        let count = await starts.count
        XCTAssertEqual(count, 2)
    }

    func testASuccessHoldsTheNextAttemptToo() async {
        let gate = ClaudeRenewalGate()
        let fresh = self.fresh
        _ = await gate.attempt(now: t0) { fresh }
        let again = await gate.attempt(now: t0.addingTimeInterval(120)) { fresh }
        XCTAssertEqual(again, .refused(.coolingDown))
    }

    func testTwoAttemptsAtOnceStartClaudeCodeOnce() async {
        let gate = ClaudeRenewalGate()
        let starts = Starts()
        let fresh = self.fresh
        let slow: @Sendable () async -> ClaudeCredentials.OAuth? = {
            await starts.add()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return fresh
        }
        // A local copy: an `async let` reading the stored `t0` would send the test case itself.
        let start = t0
        async let first = gate.attempt(now: start, slow)
        async let second = gate.attempt(now: start, slow)
        let outcomes = await [first, second]

        let count = await starts.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(outcomes.contains(.renewed(fresh)))
        XCTAssertTrue(outcomes.contains(.refused(.coolingDown)))
    }

    func testAnAttemptStillRunningPastTheCooldownHoldsTheNextOne() async {
        let gate = ClaudeRenewalGate()
        let start = t0
        let (entered, enteredGo) = AsyncStream<Void>.makeStream()
        let (release, releaseGo) = AsyncStream<Void>.makeStream()
        let first = Task {
            await gate.attempt(now: start) {
                enteredGo.yield()
                for await _ in release { break }
                return nil
            }
        }
        for await _ in entered { break }
        let later = start.addingTimeInterval(ClaudeRenewalGate.cooldown + 1)
        let admission = await gate.admission(now: later)
        let second = await gate.attempt(now: later) { nil }
        releaseGo.yield()
        let firstOutcome = await first.value

        XCTAssertEqual(admission, .coolingDown, "one at a time, whatever the clock says")
        XCTAssertEqual(second, .refused(.coolingDown))
        XCTAssertEqual(firstOutcome, .failed)
    }

    func testASignInThatNeverOpenedHoldsNothing() async {
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: t0)
        await gate.signInDidNotOpen()

        let admission = await gate.admission(now: t0.addingTimeInterval(1))

        XCTAssertEqual(admission, .run)
    }

    func testASignInFromTheButtonHoldsRenewalForTenMinutes() async {
        let gate = ClaudeRenewalGate()
        let starts = Starts()
        let fail: @Sendable () async -> ClaudeCredentials.OAuth? = { await starts.add(); return nil }
        await gate.signInLaunched(at: t0)

        let minuteLater = await gate.attempt(now: t0.addingTimeInterval(60), fail)
        let justBefore = await gate.attempt(now: t0.addingTimeInterval(599), fail)
        let tenMinutes = await gate.attempt(now: t0.addingTimeInterval(600), fail)

        XCTAssertEqual(minuteLater, .refused(.signInPending))
        XCTAssertEqual(justBefore, .refused(.signInPending))
        XCTAssertEqual(tenMinutes, .failed)
        let count = await starts.count
        XCTAssertEqual(count, 1)
    }

    func testAGoodReadingEndsThePendingSignIn() async {
        let gate = ClaudeRenewalGate()
        await gate.signInLaunched(at: t0)
        let pendingBefore = await gate.isSignInPending(now: t0.addingTimeInterval(60))
        XCTAssertTrue(pendingBefore)

        await gate.tokenArrived()

        let pendingAfter = await gate.isSignInPending(now: t0.addingTimeInterval(61))
        XCTAssertFalse(pendingAfter)
        let admission = await gate.admission(now: t0.addingTimeInterval(61))
        XCTAssertEqual(admission, .run)
    }

    func testThePendingWindowIsWhatAnActivationReads() async {
        let gate = ClaudeRenewalGate()
        let never = await gate.isSignInPending(now: t0)
        XCTAssertFalse(never, "no click, nothing pending")
        await gate.signInLaunched(at: t0)
        let atOnce = await gate.isSignInPending(now: t0)
        let late = await gate.isSignInPending(now: t0.addingTimeInterval(599))
        let over = await gate.isSignInPending(now: t0.addingTimeInterval(600))
        XCTAssertTrue(atOnce)
        XCTAssertTrue(late)
        XCTAssertFalse(over)
    }

    func testTheRuleOnItsOwn() {
        XCTAssertEqual(ClaudeRenewalGate.admission(now: t0, lastAttemptAt: nil, signInLaunchedAt: nil), .run)
        XCTAssertEqual(
            ClaudeRenewalGate.admission(now: t0, lastAttemptAt: t0.addingTimeInterval(-60), signInLaunchedAt: t0.addingTimeInterval(-60)),
            .signInPending, "a pending sign-in says more than a cooldown"
        )
        XCTAssertEqual(ClaudeRenewalGate.cooldown, 300)
        XCTAssertEqual(ClaudeRenewalGate.signInWindow, 600)
    }
}
