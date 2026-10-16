import XCTest
import CodexBarCore
@testable import Omelette

/// Verifier tests for spec 2026-10-16-antigravity-argon § "Package 2" (fresh numbers while
/// the app is closed) and the session rulings that refine it: the provider's cadence and
/// age rules at their exact edges, what a failed run may not change, what an agy reading
/// publishes against the local path, and the restore of numbers kept before the Argon fix.
/// agy is injected as the stdout it would print; time is a fixed epoch; no process starts.
final class AgyUsageVerificationTests: XCTestCase {
    private let t0 = AgyUsageFixture.readAt
    private let week: TimeInterval = 604_800
    private let fiveHours: TimeInterval = 18_000

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// Increments and returns the new count.
        @discardableResult func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// An agy stand-in that answers each run with the next of `script`, the last one for
    /// every run after.
    private final class ScriptedAgy: @unchecked Sendable {
        private let calls = Calls()
        private let script: [Result<Data, Error>]
        init(_ script: [Result<Data, Error>]) { self.script = script }
        var count: Int { calls.count }
        func fetch() async throws -> Data {
            let index = min(calls.next(), script.count) - 1
            return try script[index].get()
        }
    }

    /// A stand-in held until the test releases it; a release that comes before the run has
    /// reached it is remembered.
    private final class HeldAgy: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Data, Error>?
        private var answer: Result<Data, Error>?
        func fetch() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
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
    }

    private func provider(
        local: @escaping AntigravityProvider.StatusFetch = { throw AntigravityStatusProbeError.notRunning },
        remote: @escaping AntigravityProvider.StatusFetch = { throw AntigravityRemoteFetchError.notLoggedIn },
        agy: @escaping AntigravityProvider.AgyFetch
    ) -> AntigravityProvider {
        AntigravityProvider(localFetch: local, remoteFetch: remote, agyFetch: agy)
    }

    // MARK: - Cadence

    /// "A new run may start 280 s after the last start": 279.9 s is too soon, 280 s is not,
    /// and the clock runs from the start of a run, not from its end.
    func testARunMayStartExactlyTwoHundredEightySecondsAfterTheLastStart() async {
        let agy = ScriptedAgy([.failure(AgyUsageError.timedOut)])
        let provider = provider(agy: { try await agy.fetch() })

        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        _ = await provider.fetch(now: t0.addingTimeInterval(279.9))
        await provider.settleAgyRun()
        XCTAssertEqual(agy.count, 1, "279.9 s after the start is too soon")

        _ = await provider.fetch(now: t0.addingTimeInterval(280))
        await provider.settleAgyRun()
        XCTAssertEqual(agy.count, 2, "280 s after the start is due")

        _ = await provider.fetch(now: t0.addingTimeInterval(559.9))
        await provider.settleAgyRun()
        XCTAssertEqual(agy.count, 2, "the next interval runs from the second start (280 s), not from t0")
        _ = await provider.fetch(now: t0.addingTimeInterval(560))
        await provider.settleAgyRun()
        XCTAssertEqual(agy.count, 3)
    }

    /// "A reading is used up to 900 s old."
    func testAReadingIsShownJustInsideNineHundredSecondsAndNotJustPastThem() async {
        let agy = ScriptedAgy([.success(AgyUsageFixture.proOutput), .failure(AgyUsageError.timedOut)])
        let provider = provider(agy: { try await agy.fetch() })
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()

        let inside = await provider.fetch(now: t0.addingTimeInterval(899.9))
        await provider.settleAgyRun()
        XCTAssertEqual(inside.state, .ok)
        XCTAssertEqual(inside.buckets, AgyUsageFixture.proBuckets)

        let past = await provider.fetch(now: t0.addingTimeInterval(900.1))
        XCTAssertEqual(past.state, .notRunning)
        XCTAssertEqual(past.stateMessage, "Antigravity isn't running")
        XCTAssertTrue(past.buckets.isEmpty)
    }

    /// "Up to 900 s old": a reading exactly 900 s old is still used.
    func testAReadingExactlyNineHundredSecondsOldIsStillShown() async {
        let agy = ScriptedAgy([.success(AgyUsageFixture.proOutput), .failure(AgyUsageError.timedOut)])
        let provider = provider(agy: { try await agy.fetch() })
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let atTheEdge = await provider.fetch(now: t0.addingTimeInterval(900))
        await provider.settleAgyRun()
        XCTAssertEqual(atTheEdge.state, .ok)
        XCTAssertEqual(atTheEdge.buckets, AgyUsageFixture.proBuckets)
    }

    /// While a later run is in flight the last good reading is still shown, and the local
    /// probe is still not asked.
    func testWhileALaterRunIsInFlightTheLastReadingIsStillShown() async {
        let localCalls = Calls()
        let held = HeldAgy()
        let runs = Calls()
        let provider = provider(
            local: {
                localCalls.next()
                throw AntigravityStatusProbeError.notRunning
            },
            agy: {
                if runs.next() == 1 { return AgyUsageFixture.proOutput }
                return try await held.fetch()
            }
        )
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        XCTAssertEqual(localCalls.count, 1)

        _ = await provider.fetch(now: t0.addingTimeInterval(300)) // the second run starts, held
        let during = await provider.fetch(now: t0.addingTimeInterval(330))
        XCTAssertEqual(during.state, .ok, "the first reading is 330 s old, within the cap")
        XCTAssertEqual(during.buckets, AgyUsageFixture.proBuckets)
        XCTAssertEqual(localCalls.count, 2, "asked at 300 s (no run in flight then), not at 330 s")

        held.release(.failure(AgyUsageError.timedOut))
        await provider.settleAgyRun()
    }

    // MARK: - Remembered names

    /// "Remembered group names change only after a usable reading": no kind of failed run
    /// moves them.
    func testNoFailedRunChangesTheRememberedGroupNames() async {
        let failures: [Result<Data, Error>] = [
            .failure(AgyUsageError.timedOut),
            .failure(AgyUsageError.exitStatus(1)),
            .failure(AgyUsageError.keychainLocked),
            .success(AgyUsageFixture.signedOutOutput),
            .success(Data("not json at all".utf8)),
            .success(AgyUsageFixture.output(groups: "[]")),
            // Ultra-shaped but unusable: a bucket that reports nothing.
            .success(AgyUsageFixture.output(groups: #"[{"name":"Gemini 4 Argon","buckets":[{"id":"gemini-argon-wtu-weekly","window":"weekly"}]}]"#)),
        ]
        for failure in failures {
            let agy = ScriptedAgy([.success(AgyUsageFixture.proOutput), failure])
            let provider = provider(agy: { try await agy.fetch() })
            _ = await provider.fetch(now: t0)
            await provider.settleAgyRun()
            _ = await provider.fetch(now: t0.addingTimeInterval(300))
            await provider.settleAgyRun()
            XCTAssertEqual(agy.count, 2)

            let published = await provider.publishedBuckets(from: AntigravityFixture.proSummary)
            XCTAssertEqual(published.first { $0.kind == .modelSpecific }?.label, "Gemini 4 Argon", "\(failure)")
        }
    }

    /// A group name is taken as agy prints it, minus surrounding blanks.
    func testAGroupNameWithBlanksAroundItIsUsedTrimmed() async {
        let output = Data(String(decoding: AgyUsageFixture.proOutput, as: UTF8.self)
            .replacingOccurrences(of: #""name":"Gemini 4 Argon""#, with: #""name":"  Gemini 4 Argon \n""#).utf8)
        let provider = provider(agy: { output })
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        let snapshot = await provider.fetch(now: t0.addingTimeInterval(10))
        XCTAssertEqual(snapshot.buckets.first { $0.kind == .modelSpecific }?.label, "Gemini 4 Argon")
    }

    // MARK: - What an agy reading publishes

    private func publish(_ output: Data) async -> ServiceSnapshot {
        let provider = provider(agy: { output })
        _ = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        return await provider.fetch(now: t0.addingTimeInterval(10))
    }

    /// History keeps one line per window: the ids an agy reading publishes are the ids the
    /// local path publishes for the same windows, once each.
    func testTheIDsAreTheLocalPathsIDsOnceEach() async {
        let snapshot = await publish(AgyUsageFixture.proOutput)
        let local = AntigravityProvider.buckets(from: AntigravityFixture.proSummary)
        XCTAssertEqual(Set(snapshot.buckets.map(\.id)), Set(local.map(\.id)))
        XCTAssertEqual(snapshot.buckets.count, Set(snapshot.buckets.map(\.id)).count)
        for bucket in snapshot.buckets {
            let twin = local.first { $0.id == bucket.id }
            XCTAssertEqual(bucket.kind, twin?.kind, bucket.id)
            XCTAssertEqual(bucket.windowLength, twin?.windowLength, bucket.id)
            if bucket.kind != .modelSpecific {
                XCTAssertEqual(bucket.label, twin?.label, bucket.id)
            }
        }
    }

    /// Same windows in the same order as the local path lists them, with the same ids, kinds,
    /// lengths and (but for a per-model pool, named by agy's group) labels: Pro and Ultra.
    func testAgyListsTheWindowsInTheLocalPathsOrderForProAndUltra() async {
        let cases: [(Data, CodexBarCore.UsageSnapshot)] = [
            (AgyUsageFixture.proOutput, AntigravityFixture.proSummary),
            (AgyUsageFixture.ultraOutput, AntigravityFixture.ultraSummary),
        ]
        for (output, localReading) in cases {
            let snapshot = await publish(output)
            let local = AntigravityProvider.buckets(from: localReading)
            XCTAssertEqual(snapshot.buckets.map(\.id), local.map(\.id))
            XCTAssertEqual(snapshot.buckets.map(\.kind), local.map(\.kind))
            XCTAssertEqual(snapshot.buckets.map(\.windowLength), local.map(\.windowLength))
            XCTAssertEqual(
                snapshot.buckets.filter { $0.kind != .modelSpecific }.map(\.label),
                local.filter { $0.kind != .modelSpecific }.map(\.label)
            )
        }
    }

    /// The headline, the menu bar and the ring follow the pool windows, never Argon's.
    func testArgonAlmostSpentDoesNotDriveTheHeadlineOfAnAgyReading() async {
        let almostSpent = Data(String(decoding: AgyUsageFixture.proOutput, as: UTF8.self)
            .replacingOccurrences(of: "0.5255658626556396", with: "0.04").utf8)
        let snapshot = await publish(almostSpent)
        let argon = snapshot.buckets.first { $0.kind == .modelSpecific }
        XCTAssertEqual(argon?.utilization ?? 0, 96, accuracy: 0.0001)
        XCTAssertEqual(argon?.label, "Gemini 4 Argon")
        XCTAssertLessThan(snapshot.headlinePercent, 2, "Gemini's 5-hour window (1.0 % used) is the worst core one")
        XCTAssertEqual(WindowRanking.heroBucket(for: snapshot)?.id, "antigravity_antigravity-quota-summary-gemini-5h")
        XCTAssertEqual(WindowRanking.detailHero(for: snapshot)?.id, "antigravity_antigravity-quota-summary-gemini-5h")
    }

    /// A fraction outside 0...1 is clamped as the probe clamps it; a bucket without a reset
    /// time has none (the far future, as the local path gives it).
    func testFractionsAreClampedAndAMissingResetIsTheFarFuture() async {
        let output = AgyUsageFixture.output(groups: #"""
        [{"name":"Gemini Models","buckets":[
          {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1.5,"reset_time":"2026-10-16T12:46:06Z"},
          {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":-0.25}]}]
        """#)
        let snapshot = await publish(output)
        let five = snapshot.buckets.first { $0.id.hasSuffix("gemini-5h") }
        let weekly = snapshot.buckets.first { $0.id.hasSuffix("gemini-weekly") }
        XCTAssertEqual(five?.utilization ?? -1, 0, accuracy: 0.0001, "more than all left is 0 % used")
        XCTAssertEqual(weekly?.utilization ?? -1, 100, accuracy: 0.0001, "less than none left is 100 % used")
        XCTAssertEqual(weekly?.resetsAt, .distantFuture)
        XCTAssertEqual(five?.resetsAt, Date(timeIntervalSince1970: 1_792_154_766))
    }

    /// No model table: a per-model pool that appears next month is a per-model row under its
    /// group's name, whatever the group is called, with the window length agy gave it.
    func testAFutureGroupIsAPerModelRowUnderItsGroupName() async {
        let output = AgyUsageFixture.output(groups: #"""
        [{"name":"Gemini Models","buckets":[
          {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.9,"reset_time":"2026-10-16T12:46:06Z"}]},
         {"name":"Gemini 5 Zinc","buckets":[
          {"id":"gemini-zinc-weekly","name":"Zinc Weekly Limit","window":"weekly","remaining_fraction":0.25,"reset_time":"2026-10-23T07:45:44Z"}]},
         {"name":"Fable Models","buckets":[
          {"id":"fable-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.5,"reset_time":"2026-10-16T13:00:00Z"}]}]
        """#)
        let snapshot = await publish(output)
        let zinc = snapshot.buckets.first { $0.id == "antigravity_antigravity-quota-summary-gemini-zinc-weekly" }
        XCTAssertEqual(zinc?.label, "Gemini 5 Zinc")
        XCTAssertEqual(zinc?.kind, .modelSpecific)
        XCTAssertEqual(zinc?.windowLength, week)
        XCTAssertEqual(zinc?.utilization ?? 0, 75, accuracy: 0.0001)
        let fable = snapshot.buckets.first { $0.id == "antigravity_antigravity-quota-summary-fable-5h" }
        XCTAssertEqual(fable?.label, "Fable Models")
        XCTAssertEqual(fable?.kind, .modelSpecific)
        XCTAssertEqual(fable?.windowLength, fiveHours)
        let pool = snapshot.buckets.first { $0.id.hasSuffix("gemini-5h") }
        XCTAssertEqual(pool?.kind, .session)
        XCTAssertEqual(pool?.label, "Gemini 5-hour")
    }

    /// Every agy reading is `.ok` with the same service identity the rest of the app keys on.
    func testAnAgyReadingIsTheAntigravityServiceInTheOKState() async {
        let snapshot = await publish(AgyUsageFixture.proOutput)
        XCTAssertEqual(snapshot.id, "antigravity")
        XCTAssertEqual(snapshot.displayName, "Antigravity")
        XCTAssertEqual(snapshot.state, .ok)
        XCTAssertNil(snapshot.stateMessage)
        XCTAssertNil(snapshot.extraUsage)
        XCTAssertNil(snapshot.weekCost)
    }

    /// A provider built without an agy step never reaches for one.
    func testAProviderWithoutAnAgyStepStaysOnTheWebFallback() async {
        let provider = AntigravityProvider(
            localFetch: { throw AntigravityStatusProbeError.notRunning },
            remoteFetch: { throw AntigravityRemoteFetchError.notLoggedIn }
        )
        let snapshot = await provider.fetch(now: t0)
        await provider.settleAgyRun()
        XCTAssertEqual(snapshot.state, .notRunning)
    }

    // MARK: - Numbers kept from before the Argon fix

    private func oldShape(argonLabel: String = "Gemini weekly", argonKind: BucketKind = .weekly) -> [UsageBucket] {
        let prefix = "antigravity_antigravity-quota-summary-"
        return [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 47.44,
                           resetsAt: AntigravityFixture.argonWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: AntigravityFixture.thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: prefix + "gemini-5h", label: "Gemini 5-hour", percent: 0.04,
                           resetsAt: AntigravityFixture.gemini5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: prefix + "gemini-weekly", label: "Gemini weekly", percent: 0.01,
                           resetsAt: AntigravityFixture.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: prefix + "gemini-argon-wtu-weekly", label: argonLabel, percent: 47.44,
                           resetsAt: AntigravityFixture.argonWeeklyReset, kind: argonKind, windowLength: week),
            Fixture.bucket(id: prefix + "3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: AntigravityFixture.thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: prefix + "3p-weekly", label: "Claude/GPT weekly", percent: 0,
                           resetsAt: AntigravityFixture.thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ]
    }

    /// The purpose of the restore: the closed app's tab and menu bar no longer follow Argon.
    func testARestoredReadingNoLongerDrivesTheHeadlineFromArgon() {
        let before = Fixture.snapshot(id: "antigravity", buckets: oldShape())
        XCTAssertGreaterThan(before.headlinePercent, 47, "the bug being restored away")

        let restored = Fixture.snapshot(id: "antigravity", buckets: AntigravityProvider.restoredBuckets(oldShape()))
        XCTAssertLessThan(restored.headlinePercent, 1)
        XCTAssertEqual(WindowRanking.heroBucket(for: restored)?.id, "antigravity_antigravity-quota-summary-gemini-5h")
        XCTAssertEqual(restored.buckets.filter { $0.kind == .modelSpecific }.map(\.id),
                       ["antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly"])
        XCTAssertFalse(restored.buckets.contains { $0.id == "antigravity_gemini" || $0.id == "antigravity_claude_gpt" })
    }

    func testRestoringTwiceIsRestoringOnce() {
        let once = AntigravityProvider.restoredBuckets(oldShape())
        XCTAssertEqual(AntigravityProvider.restoredBuckets(once), once)
    }

    /// The other buckets keep their order, ids, labels, numbers and resets.
    func testRestoreChangesNothingButTheAggregatesAndArgon() {
        let old = oldShape()
        let restored = AntigravityProvider.restoredBuckets(old)
        let untouched = old.filter { !$0.id.contains("argon") && $0.id != "antigravity_gemini" && $0.id != "antigravity_claude_gpt" }
        XCTAssertEqual(restored.filter { !$0.id.contains("argon") }, untouched)
        let argon = restored.first { $0.id.contains("argon") }
        XCTAssertEqual(argon?.utilization, 47.44)
        XCTAssertEqual(argon?.resetsAt, AntigravityFixture.argonWeeklyReset)
        XCTAssertEqual(argon?.windowLength, week)
        XCTAssertEqual(argon?.kind, .modelSpecific)
        XCTAssertNotEqual(argon?.label, "Gemini weekly", "no longer a second \"Gemini weekly\"")
    }

    /// A stored reading from a plan without Argon (Ultra) loses only the aggregates.
    func testAStoredReadingWithoutArgonLosesOnlyTheAggregates() {
        let old = oldShape().filter { !$0.id.contains("argon") }
        let restored = AntigravityProvider.restoredBuckets(old)
        XCTAssertEqual(restored.map(\.id), old.map(\.id).filter { $0 != "antigravity_gemini" && $0 != "antigravity_claude_gpt" })
        XCTAssertFalse(restored.contains { $0.kind == .modelSpecific })
    }

    /// A stored reading that is empty, or holds no Antigravity bucket at all, comes back as it was.
    func testNothingToRestoreStaysNothing() {
        XCTAssertEqual(AntigravityProvider.restoredBuckets([]), [])
        let foreign = [Fixture.bucket(id: "five_hour", label: "Current session", percent: 7, kind: .session)]
        XCTAssertEqual(AntigravityProvider.restoredBuckets(foreign), foreign)
    }

    // MARK: - Keychain gate

    func testTheLockStateAndTheOlderBooleanAgree() {
        let state = KeychainNoUI.defaultKeychainLockState
        XCTAssertEqual(KeychainNoUI.isDefaultKeychainUnlocked, state != .locked,
                       "an unreadable state still answers \"unlocked\" to the older callers")
    }
}
