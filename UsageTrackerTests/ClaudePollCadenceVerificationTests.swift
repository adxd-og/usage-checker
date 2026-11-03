import XCTest
@testable import Omelette

/// Spec 2026-11-02 Claude limits from the status line, § Design › Cadence (P3), judged
/// from the spec and not from the executor's tests: while a reading is applied, Claude's
/// OAuth endpoint is asked at most every max(refreshIntervalSeconds, 300) s, otherwise
/// at every tick; the popover-open refresh still asks; a held tick shows Claude's last
/// answer, on which the status-line merge still wins where it is newer. The poll loop
/// itself (`AppState.shared`) cannot run without real providers, so `PollLoop` replays
/// `startRefresh` / `performRefresh`'s use of the rules, call for call.
final class ClaudePollCadenceVerificationTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let t0 = Date(timeIntervalSince1970: 1_788_693_600)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private var defaultDir: String { StatusLineMergeRules.defaultConfigDir(home: StatusLineFixture.home) }

    private func claude(
        percent: Double = 20, state: ServiceState = .ok, retryAfter: TimeInterval? = nil, fetchedAt: Date
    ) -> ServiceSnapshot {
        var snapshot = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: state == .ok
                ? [
                    Fixture.bucket(
                        id: "five_hour", label: "Current session", percent: percent,
                        resetsAt: StatusLineFixture.fiveHourResetsAt, kind: .session
                    ),
                    Fixture.bucket(
                        id: "seven_day", label: "All models", percent: 40,
                        resetsAt: StatusLineFixture.sevenDayResetsAt, kind: .weekly
                    ),
                ]
                : [],
            state: state, stateMessage: state == .ok ? nil : "Rate limited by usage API", at: fetchedAt
        )
        snapshot.retryAfter = retryAfter
        return snapshot
    }

    private func reading(asOf: Date) -> [StatusLineFreshnessRules.Session] {
        [StatusLineFreshnessRules.Session(
            sessionID: StatusLineFixture.sessionID, promptID: StatusLineFixture.promptID,
            totalAPIDurationMs: 18_250, asOf: asOf, writtenAt: asOf,
            fiveHour: StatusLineFixture.fiveHour, sevenDay: StatusLineFixture.sevenDay,
            configDir: StatusLineFixture.configDir
        )]
    }

    // MARK: - The poll loop's use of the rules

    /// `AppState.startRefresh` + `performRefresh`, as far as the cadence is concerned.
    private struct PollLoop {
        var setting: Int
        var claudeOn = true
        var answerState = ServiceState.ok
        var lastFetch: ClaudePollCadenceRules.LastFetch?
        var appliedAt: Date?
        var lastRefreshAt = Date.distantPast
        var asks: [Date] = []
        var heldTicks: [Date] = []

        init(setting: Int) { self.setting = setting }

        /// One poll at `now`. `reading` says the status line fed Claude's windows at it.
        @discardableResult
        mutating func poll(
            _ trigger: ClaudePollCadenceRules.Trigger, at now: Date, reading: Bool
        ) -> Bool {
            let held = ClaudePollCadenceRules.heldAnswer(
                last: lastFetch, claudeEnabled: claudeOn, trigger: trigger,
                statusLineAppliedAt: appliedAt, refreshIntervalSeconds: setting, now: now
            )
            lastRefreshAt = ClaudePollCadenceRules.refreshStamp(
                previous: lastRefreshAt, pollAt: now, held: held != nil
            )
            let answer = held ?? ServiceSnapshot.verificationAnswer(at: now, state: answerState)
            if held == nil { asks.append(now) } else { heldTicks.append(now) }
            lastFetch = ClaudePollCadenceRules.lastFetch(
                after: claudeOn ? [answer] : [], held: held, previous: lastFetch, at: now
            )
            if reading { appliedAt = now }
            return held == nil
        }
    }

    private func tickTimes(setting: Int, hours: Double = 1, jitter: (Int) -> TimeInterval = { _ in 0 }) -> [Date] {
        // The timer sleeps max(15, setting) between ticks (`AppState.startTimer`).
        let step = TimeInterval(max(15, setting))
        let count = Int(hours * 3600 / step)
        return (0...count).map { at(TimeInterval($0) * step + jitter($0)) }
    }

    func testWhileTheStatusLineFeedsItTheEndpointIsAskedEveryFiveMinutesAtEverySetting() {
        for setting in [15, 60, 300, 600] {
            var loop = PollLoop(setting: setting)
            for tick in tickTimes(setting: setting) { loop.poll(.tick, at: tick, reading: true) }

            let gaps = zip(loop.asks, loop.asks.dropFirst()).map { $1.timeIntervalSince($0) }
            XCTAssertFalse(gaps.isEmpty, "setting \(setting)")
            XCTAssertEqual(
                Set(gaps), [max(TimeInterval(setting), 300)],
                "setting \(setting): never sooner, never later than max(setting, 300) s"
            )
        }
    }

    func testWithoutAReadingEveryTickAsksAtEverySetting() {
        for setting in [15, 60, 300, 600] {
            var loop = PollLoop(setting: setting)
            let ticks = tickTimes(setting: setting)
            for tick in ticks { loop.poll(.tick, at: tick, reading: false) }

            XCTAssertEqual(loop.asks, ticks, "setting \(setting)")
            XCTAssertTrue(loop.heldTicks.isEmpty)
        }
    }

    func testTicksThatDriftAFewSecondsStillAskEveryFiveMinutes() {
        var loop = PollLoop(setting: 60)
        let wobble: [TimeInterval] = [0, 2, -2, 1, -1, 2, -2, 0, 2, -2]
        for tick in tickTimes(setting: 60, hours: 2, jitter: { wobble[$0 % wobble.count] }) {
            loop.poll(.tick, at: tick, reading: true)
        }

        let gaps = zip(loop.asks, loop.asks.dropFirst()).map { $1.timeIntervalSince($0) }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 295, "never more often than the tolerance allows")
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, 305, "a due tick a hair early is not held a whole minute more")
    }

    func testWhenTheStatusLineGoesQuietEveryTickAsksAgainAfterFiveMinutes() {
        var loop = PollLoop(setting: 60)
        let ticks = tickTimes(setting: 60)
        for tick in ticks { loop.poll(.tick, at: tick, reading: tick <= at(120)) }

        // The last reading was applied at +120 s: held through +420 s, every tick after.
        let late = ticks.filter { $0 > at(420) }
        XCTAssertFalse(late.isEmpty)
        XCTAssertTrue(Set(late).isSubset(of: Set(loop.asks)), "every tick after the hold asks")
        XCTAssertTrue(loop.heldTicks.contains(at(360)), "and before it, the ticks in between are held")
    }

    func testAnIslandOpenedRightAfterAHeldTickAsksAndTheFiveMinutesRestartFromIt() {
        var loop = PollLoop(setting: 60)
        for tick in tickTimes(setting: 60, hours: 0.2) where tick <= at(120) {
            loop.poll(.tick, at: tick, reading: true)
        }
        XCTAssertEqual(loop.heldTicks, [at(60), at(120)])

        // 3 s after the held tick at +120 s: the floor measures from the poll that asked.
        let open = at(123)
        XCTAssertTrue(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: loop.lastRefreshAt, now: open))
        XCTAssertTrue(loop.poll(.asked, at: open, reading: true), "the open asks Claude's endpoint")
        XCTAssertFalse(
            AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: loop.lastRefreshAt, now: at(130)),
            "and a poll that asked keeps the ten-second floor"
        )

        XCTAssertFalse(loop.poll(.tick, at: at(180), reading: true), "the next tick holds")
        XCTAssertFalse(loop.poll(.tick, at: at(410), reading: true), "still held 287 s after the open")
        XCTAssertTrue(loop.poll(.tick, at: at(420), reading: true), "asks again 297 s after the open")
    }

    func testClaudeSwitchedOffForgetsTheLastFetchAndTheFirstPollAfterAsks() {
        var loop = PollLoop(setting: 60)
        loop.poll(.tick, at: at(0), reading: true)
        XCTAssertNotNil(loop.lastFetch)

        loop.claudeOn = false
        loop.poll(.tick, at: at(60), reading: true)
        XCTAssertNil(loop.lastFetch, "off forgets it")

        loop.claudeOn = true
        XCTAssertTrue(loop.poll(.tick, at: at(120), reading: true), "back on, the first poll asks")
    }

    func testAClockThatMovedBackHoldsNothingInTheLoop() {
        var loop = PollLoop(setting: 60)
        loop.poll(.tick, at: at(600), reading: true)
        XCTAssertTrue(loop.poll(.tick, at: at(540), reading: true), "the last fetch is in the future")
        XCTAssertTrue(loop.poll(.tick, at: at(500), reading: true))
    }

    // MARK: - What a held poll shows

    func testAHeldAnswerKeepsItsOldFetchTimeAndTheNewerReadingStillWinsOnTopOfIt() throws {
        let answer = claude(percent: 20, retryAfter: 90, fetchedAt: at(-240))
        let held = try XCTUnwrap(ClaudePollCadenceRules.heldAnswer(
            last: .init(snapshot: answer, at: at(-240)), claudeEnabled: true, trigger: .tick,
            statusLineAppliedAt: at(-60), refreshIntervalSeconds: 60, now: t0
        ))
        XCTAssertEqual(held.fetchedAt, at(-240), "a held answer is not re-dated")
        XCTAssertNil(held.retryAfter)

        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", at: t0)
        let poll = UsageSnapshot(services: [held, codex], fetchedAt: t0, isStale: false, lastError: nil)
        let shown = AppState.shownAfterPoll(
            previous: .empty, next: poll, stored: [:], statusLine: reading(asOf: at(-60)),
            defaultConfigDir: defaultDir, now: t0
        )

        XCTAssertTrue(shown.applied, "a reading newer than the held answer's fetch still feeds")
        let shownClaude = try XCTUnwrap(shown.snapshot.services.first)
        XCTAssertEqual(shownClaude.buckets.map(\.utilization), [23.5, 41.2])
        XCTAssertEqual(shownClaude.buckets.map(\.source), [.statusLine, .statusLine])
        XCTAssertEqual(shownClaude.fetchedAt, at(-240))
        XCTAssertNil(shownClaude.retryAfter)
        XCTAssertEqual(shown.snapshot.services.last, codex, "the other providers are as polled")
        XCTAssertNil(shown.snapshot.services.compactMap(\.retryAfter).max(), "no backoff is re-armed by a held answer")
    }

    func testAReadingOlderThanTheHeldAnswersFetchDoesNotOverrideIt() throws {
        let answer = claude(percent: 20, fetchedAt: at(-30))
        let poll = UsageSnapshot(services: [answer], fetchedAt: t0, isStale: false, lastError: nil)

        let shown = AppState.shownAfterPoll(
            previous: .empty, next: poll, stored: [:], statusLine: reading(asOf: at(-120)),
            defaultConfigDir: defaultDir, now: t0
        )

        XCTAssertFalse(shown.applied, "newer wins: an applied flag here would keep the endpoint slow for nothing")
        XCTAssertEqual(shown.snapshot.services.first?.buckets.map(\.utilization), [20, 40])
    }

    /// Session ruling 2026-11-03: only a good answer is held; a failed, signed-out or
    /// rate-limited one is asked again at the next tick (Retry-After alone spaces the asks,
    /// in `AppState.refreshNow`).
    func testAFailedAnswerIsAskedAgainAtTheNextTick() {
        for state in [ServiceState.error, .notSignedIn, .notRunning] {
            let failed = claude(state: state, retryAfter: 200, fetchedAt: at(-60))
            let last = ClaudePollCadenceRules.LastFetch(snapshot: failed, at: at(-60))
            for seconds in [1.0, 60, 120, 239, 240] as [TimeInterval] {
                XCTAssertNil(
                    ClaudePollCadenceRules.heldAnswer(
                        last: last, claudeEnabled: true, trigger: .tick,
                        statusLineAppliedAt: at(seconds - 30), refreshIntervalSeconds: 60, now: at(seconds)
                    ),
                    "\(state): a tick \(seconds) s in asks again"
                )
            }
        }
    }

    func testEveryTickAsksWhileClaudeAnswersWithAFailureEvenIfTheStatusLineFeeds() {
        var loop = PollLoop(setting: 60)
        loop.answerState = .notSignedIn
        let ticks = tickTimes(setting: 60, hours: 0.5)
        for tick in ticks { loop.poll(.tick, at: tick, reading: true) }
        XCTAssertEqual(loop.asks, ticks)

        // Signed in again: the next good answer is held as before.
        loop.answerState = .ok
        let after = ticks.last!.addingTimeInterval(60)
        XCTAssertTrue(loop.poll(.tick, at: after, reading: true))
        XCTAssertFalse(loop.poll(.tick, at: after.addingTimeInterval(60), reading: true))
    }

    func testASignedOutClaudeFedByTheStatusLineKeepsItsChipAndItsBackoff() throws {
        let failed = claude(state: .notSignedIn, retryAfter: 120, fetchedAt: t0)
        let poll = UsageSnapshot(services: [failed], fetchedAt: t0, isStale: false, lastError: nil)

        let shown = AppState.shownAfterPoll(
            previous: .empty, next: poll, stored: [:], statusLine: reading(asOf: at(-60)),
            defaultConfigDir: defaultDir, now: t0
        )

        let shownClaude = try XCTUnwrap(shown.snapshot.services.first)
        XCTAssertEqual(shownClaude.state, .notSignedIn, "dimmed stays: the chip is still there")
        XCTAssertEqual(shownClaude.buckets.map(\.utilization), [23.5, 41.2])
        XCTAssertEqual(shownClaude.retryAfter, 120, "a fresh failure's Retry-After still arms the backoff")
    }

    func testAskedPollsAreNeverHeldWhateverTheReadingSays() {
        let last = ClaudePollCadenceRules.LastFetch(snapshot: claude(fetchedAt: at(-1)), at: at(-1))
        for setting in [15, 60, 300, 600] {
            XCTAssertNil(ClaudePollCadenceRules.heldAnswer(
                last: last, claudeEnabled: true, trigger: .asked,
                statusLineAppliedAt: at(-1), refreshIntervalSeconds: setting, now: t0
            ), "setting \(setting)")
        }
    }
}

private extension ServiceSnapshot {
    /// What a fetch at `date` hands back, for the loop replay.
    static func verificationAnswer(at date: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 20, kind: .session)],
            state: state, at: date
        )
    }
}
