import XCTest
@testable import Omelette

/// Stands in for the monitor's sleep: records each interval, fulfils the expectation waiting on
/// that many sleeps, then parks until the loop that called it is cancelled, so the loop goes no
/// further. No clock: a sleep ends only when the monitor cancels its loop, and the probe counts
/// those ends too, so a test can wait for a replaced loop to have left its sleep.
private final class SleepProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var cancelled = 0
    private var waitingForSleep: [Int: XCTestExpectation] = [:]
    private var waitingForCancel: [Int: XCTestExpectation] = [:]

    var intervals: [TimeInterval] { lock.withLock { recorded } }
    /// The loops parked in a sleep right now.
    var asleep: Int { lock.withLock { recorded.count - cancelled } }

    func expect(_ expectation: XCTestExpectation, atSleep count: Int) {
        lock.withLock { waitingForSleep[count] = expectation }
    }

    func expect(_ expectation: XCTestExpectation, atCancelledSleep count: Int) {
        lock.withLock { waitingForCancel[count] = expectation }
    }

    func sleep(_ seconds: TimeInterval) async {
        let reached: XCTestExpectation? = lock.withLock {
            recorded.append(seconds)
            return waitingForSleep.removeValue(forKey: recorded.count)
        }
        reached?.fulfill()
        await Self.untilCancelled()
        let left: XCTestExpectation? = lock.withLock {
            cancelled += 1
            return waitingForCancel.removeValue(forKey: cancelled)
        }
        left?.fulfill()
    }

    /// Returns once the calling task is cancelled, at once when it already is.
    private static func untilCancelled() async {
        let (parked, wake) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in parked {}
        } onCancel: {
            wake.finish()
        }
    }
}

/// Holds the sampler inside its first read of the process table until the test lets it go, so a
/// test can act while a sample is in flight. Later reads pass straight through.
private final class TableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var passedOnce = false
    private let entered: XCTestExpectation
    private let released = DispatchSemaphore(value: 0)

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func pass() {
        let first = lock.withLock { () -> Bool in
            defer { passedOnce = true }
            return !passedOnce
        }
        guard first else { return }
        entered.fulfill()
        released.wait()
    }

    func release() {
        released.signal()
    }
}

/// Spec 2026-11-19 agent resources § Sampling: only while at least one session with a tty is
/// live; every 5 s while the island or the Agents tab is open, counted per view instance; every
/// 30 s otherwise; nothing when no session is live; never on the main actor. § Which processes:
/// a session without a tty has no figures (Decision 3); when several live sessions share one tty,
/// only the most recently active one gets the tty's figures; a tty whose every process started
/// after the session's last event is a newer tab's, and the session gets none.
final class AgentResourceMonitorTests: XCTestCase {
    private typealias F = AgentProcessFixture

    private func session(
        _ id: String, tty: String?, approximate: Bool = false, lastEventAt: Date = AgentProcessFixture.t0
    ) -> AgentSession {
        Fixture.agentSession(
            sessionID: id, lastEventAt: lastEventAt,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: tty), isApproximate: approximate
        )
    }

    @MainActor
    private func makeMonitor(_ machine: FakeMachine, _ probe: SleepProbe) -> AgentResourceMonitor {
        AgentResourceMonitor(sampler: machine.sampler(), now: { AgentProcessFixture.t0 }, sleep: { await probe.sleep($0) })
    }

    // MARK: Rules

    func testTheTTYsAreTheLiveSessionsOnesOnceEach() {
        let sessions = [
            session("a", tty: F.tab), session("b", tty: F.tab), session("c", tty: F.pane),
            session("ide", tty: nil), session("blank", tty: ""),
            session("scanned", tty: nil, approximate: true),
        ]
        XCTAssertEqual(AgentResourceRules.ttys(of: sessions), [F.tab, F.pane])
    }

    func testASessionWithoutATTYHasNoFigures() {
        let measured = AgentResourceRules.Figures(cpuPercent: 212, memoryBytes: 3 * 1024 * F.mb)
        let tab = session("a", tty: F.tab)
        let panel = session("ide", tty: nil)
        let blank = session("blank", tty: "")
        let unread = session("b", tty: F.pane)
        XCTAssertEqual(AgentResourceRules.owners(of: [tab, panel, blank, unread]), [tab.id: F.tab, unread.id: F.pane])
        XCTAssertEqual(
            AgentResourceRules.bySession([tab, panel, blank, unread], byTTY: [F.tab: measured]), [tab.id: measured],
            "no tty, a blank tty, a tty not read yet: nothing"
        )
    }

    /// § Which processes: a `claude` that ended without `SessionEnd` stays live while its tab is
    /// open; the new one in the same tab gets the tty's figures, the old one none. "Most recently
    /// active" reads `lastEventAt`; a tie goes to the smaller id, as the store's display order.
    func testOnlyTheMostRecentlyActiveSessionOnATTYGetsItsFigures() {
        let older = session("old", tty: F.tab, lastEventAt: F.t0.addingTimeInterval(-3600))
        let newer = session("new", tty: F.tab, lastEventAt: F.t0)
        let alone = session("other", tty: F.pane, lastEventAt: F.t0.addingTimeInterval(-7200))
        XCTAssertEqual(AgentResourceRules.owners(of: [older, newer, alone]), [newer.id: F.tab, alone.id: F.pane])
        let measured = AgentResourceRules.Figures(cpuPercent: 212, memoryBytes: 3 * 1024 * F.mb)
        XCTAssertEqual(
            AgentResourceRules.bySession([older, newer, alone], byTTY: [F.tab: measured]), [newer.id: measured],
            "one tree, counted once"
        )
        let first = session("a", tty: F.otherTab, lastEventAt: F.t0)
        let second = session("b", tty: F.otherTab, lastEventAt: F.t0)
        XCTAssertEqual(AgentResourceRules.owners(of: [second, first]), [first.id: F.otherTab])
    }

    /// § Which processes (review F4): a tty whose every process started after the session's last
    /// event belongs to a newer tab that got the device name after the session's tab closed; the
    /// session gets no figures. One process as old as the last event, or older, keeps them.
    func testATTYWhoseEveryProcessStartedAfterTheSessionsLastEventIsANewerTabs() throws {
        let tty = "/dev/ttys007"
        let lastEvent = F.t0.addingTimeInterval(-600)
        let ghost = session("ghost", tty: tty, lastEventAt: lastEvent)
        func shown(startingAt offsets: [TimeInterval]) throws -> AgentResourceRules.Figures? {
            let table = offsets.enumerated().map { index, offset in
                F.row(
                    pid_t(900 + index), index == 0 ? 400 : pid_t(899 + index), tty,
                    started: lastEvent.addingTimeInterval(offset)
                )
            }
            let read = try XCTUnwrap(AgentResourceRules.reading(
                of: tty, in: table, usage: { _ in F.usage(1, 100) }, at: F.t0
            ))
            let figures = AgentResourceRules.figures(previous: nil, current: read, cores: AgentProcessFixture.cores)
            return AgentResourceRules.bySession([ghost], byTTY: [tty: figures])[ghost.id]
        }
        XCTAssertNil(try shown(startingAt: [60, 61, 90]), "every process newer than the last event: a newer tab's")
        XCTAssertNotNil(try shown(startingAt: [-60, 61, 90]), "one process older: still the session's")
        XCTAssertNotNil(try shown(startingAt: [0, 61, 90]), "as old as the last event: still the session's")
    }

    func testFiveSecondsWatchedThirtyOtherwiseNoneWithoutATTY() {
        XCTAssertNil(AgentResourceRules.interval(ttys: 0, watched: true))
        XCTAssertNil(AgentResourceRules.interval(ttys: 0, watched: false))
        XCTAssertEqual(AgentResourceRules.interval(ttys: 1, watched: false), 30)
        XCTAssertEqual(AgentResourceRules.interval(ttys: 3, watched: true), 5)
    }

    // MARK: Monitor

    @MainActor
    func testNothingRunsWhileNoSessionHasATTY() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        monitor.update(sessions: [session("ide", tty: nil), session("scanned", tty: nil, approximate: true)])
        monitor.setWatching(.island, by: UUID(), true)
        XCTAssertNil(monitor.cadence)
        XCTAssertFalse(monitor.isSampling)
        await Task.yield()
        XCTAssertEqual(machine.tableReads, 0)
        XCTAssertEqual(monitor.byTTY, [:])
    }

    @MainActor
    func testATTYSessionIsSampledAtOnceThenEveryThirtySeconds() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let slept = expectation(description: "the loop sampled, then went to sleep")
        probe.expect(slept, atSleep: 1)
        let tab = session("a", tty: F.tab)
        monitor.update(sessions: [tab])
        await fulfillment(of: [slept], timeout: 5)
        XCTAssertEqual(monitor.cadence, 30)
        XCTAssertEqual(probe.intervals, [30])
        let read = AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 1899 * F.mb, oldestStart: F.tabOpened)
        XCTAssertEqual(monitor.byTTY[F.tab], read)
        XCTAssertEqual(monitor.bySession, [tab.id: read])
        monitor.update(sessions: [])
    }

    @MainActor
    func testOpeningTheIslandSamplesEveryFiveSeconds() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let first = expectation(description: "first sleep")
        let second = expectation(description: "second sleep")
        probe.expect(first, atSleep: 1)
        probe.expect(second, atSleep: 2)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [first], timeout: 5)
        monitor.setWatching(.island, by: UUID(), true)
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(probe.intervals, [30, 5])
        XCTAssertEqual(monitor.cadence, 5)
        monitor.update(sessions: [])
    }

    /// § Sampling: one loop at a time. A change of the open surfaces replaces the loop, and the
    /// one before has to end: left parked in its sleep it would wake at its own cadence and
    /// sample beside its replacement.
    @MainActor
    func testReplacingTheLoopEndsTheOneBefore() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let first = expectation(description: "the first loop sleeps")
        let ended = expectation(description: "the first loop's sleep was cancelled")
        let second = expectation(description: "its replacement sleeps")
        probe.expect(first, atSleep: 1)
        probe.expect(ended, atCancelledSleep: 1)
        probe.expect(second, atSleep: 2)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [first], timeout: 5)
        monitor.setWatching(.island, by: UUID(), true)
        await fulfillment(of: [ended, second], timeout: 5)
        XCTAssertEqual(probe.intervals, [30, 5])
        XCTAssertEqual(probe.asleep, 1, "one loop, not two")
        monitor.update(sessions: [])
    }

    @MainActor
    func testTheFastCadenceLastsWhileEitherSurfaceIsOpen() {
        let monitor = makeMonitor(FakeMachine(), SleepProbe())
        monitor.update(sessions: [session("a", tty: F.tab)])
        let island = UUID(), agentsTab = UUID()
        monitor.setWatching(.island, by: island, true)
        monitor.setWatching(.agentsTab, by: agentsTab, true)
        monitor.setWatching(.island, by: island, false)
        XCTAssertEqual(monitor.cadence, 5, "the Agents tab is still open")
        monitor.setWatching(.agentsTab, by: agentsTab, false)
        XCTAssertEqual(monitor.cadence, 30)
        monitor.update(sessions: [])
    }

    /// § Sampling (review F2): a surface counts as open per view instance. The dashboard rebuilds
    /// the Agents tab when it shows again, and the old view's late "gone" must not switch off the
    /// view that replaced it.
    @MainActor
    func testALateFalseFromAReplacedViewCannotSwitchOffItsReplacement() {
        let monitor = makeMonitor(FakeMachine(), SleepProbe())
        monitor.update(sessions: [session("a", tty: F.tab)])
        let replaced = UUID(), replacement = UUID()
        monitor.setWatching(.agentsTab, by: replaced, true)
        monitor.setWatching(.agentsTab, by: replacement, true)
        monitor.setWatching(.agentsTab, by: replaced, false)
        XCTAssertEqual(monitor.cadence, 5, "the new view is on screen")
        monitor.setWatching(.agentsTab, by: replaced, false)
        XCTAssertEqual(monitor.cadence, 5, "a second late false changes nothing")
        monitor.setWatching(.agentsTab, by: replacement, false)
        XCTAssertEqual(monitor.cadence, 30, "both views gone")
        monitor.update(sessions: [])
    }

    /// § Sampling: per view instance, not per call. The dashboard's visibility reader can say
    /// "visible" again for a view already counted, and "gone" for a view that never showed: the
    /// first holds the surface once, the second releases nothing.
    @MainActor
    func testAViewCountsOnceHoweverOftenItSaysItIsOnScreen() {
        let monitor = makeMonitor(FakeMachine(), SleepProbe())
        monitor.update(sessions: [session("a", tty: F.tab)])
        monitor.setWatching(.agentsTab, by: UUID(), false)
        XCTAssertEqual(monitor.cadence, 30, "a view that never showed left: nothing to release")
        let view = UUID()
        monitor.setWatching(.agentsTab, by: view, true)
        monitor.setWatching(.agentsTab, by: view, true)
        monitor.setWatching(.agentsTab, by: UUID(), false)
        XCTAssertEqual(monitor.cadence, 5, "another view's gone does not release this one")
        monitor.setWatching(.agentsTab, by: view, false)
        XCTAssertEqual(monitor.cadence, 30, "said twice, held once")
        monitor.update(sessions: [])
    }

    @MainActor
    func testTheLastTTYLeavingStopsSamplingAndClearsTheFigures() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let slept = expectation(description: "first sample")
        let ended = expectation(description: "the loop left its sleep, cancelled")
        probe.expect(slept, atSleep: 1)
        probe.expect(ended, atCancelledSleep: 1)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [slept], timeout: 5)
        monitor.update(sessions: [session("ide", tty: nil)])
        XCTAssertFalse(monitor.isSampling)
        XCTAssertNil(monitor.cadence)
        XCTAssertEqual(monitor.byTTY, [:])
        XCTAssertEqual(monitor.bySession, [:])
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(probe.asleep, 0, "no loop is left waiting to sample again")
    }

    /// § Sampling: nothing when no session is live. A sample still being read when the last tty
    /// leaves comes back to a loop that was cancelled meanwhile, and its figures must not come
    /// back with it: no loop is left to clear them.
    @MainActor
    func testASampleInFlightWhenTheLastTTYLeavesPublishesNothing() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let reading = expectation(description: "the sampler is inside its read of the table")
        let gate = TableGate(entered: reading)
        let sampler = AgentResourceSampler(
            table: {
                gate.pass()
                return machine.readTable()
            },
            usage: { machine.usage($0) }
        )
        let monitor = AgentResourceMonitor(
            sampler: sampler, now: { AgentProcessFixture.t0 }, sleep: { await probe.sleep($0) }
        )
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [reading], timeout: 5)
        monitor.update(sessions: [])
        gate.release()
        // The sampler answers one caller at a time and the main actor runs its jobs in the order
        // they arrived: once this call is back, the cancelled loop has been handed its figures.
        _ = await sampler.sample(ttys: [], now: F.t0)
        XCTAssertEqual(machine.tableReads, 1, "the sample did run")
        XCTAssertFalse(monitor.isSampling)
        XCTAssertEqual(monitor.byTTY, [:])
        XCTAssertEqual(monitor.bySession, [:])
    }

    @MainActor
    func testANewerSessionOnTheSameTTYTakesItsFigures() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let slept = expectation(description: "first sample")
        probe.expect(slept, atSleep: 1)
        let older = session("old", tty: F.tab, lastEventAt: F.t0.addingTimeInterval(-3600))
        monitor.update(sessions: [older])
        await fulfillment(of: [slept], timeout: 5)
        XCTAssertEqual(Set(monitor.bySession.keys), [older.id])
        let newer = session("new", tty: F.tab, lastEventAt: F.t0)
        monitor.update(sessions: [older, newer])
        XCTAssertEqual(Set(monitor.bySession.keys), [newer.id], "one tree, counted once")
        XCTAssertEqual(probe.intervals, [30], "the same tty: the loop runs on, no new sample")
        monitor.update(sessions: [])
    }

    @MainActor
    func testTheProcessTableIsNeverReadOnTheMainThread() async {
        let machine = FakeMachine(), probe = SleepProbe()
        let monitor = makeMonitor(machine, probe)
        let slept = expectation(description: "first sample")
        probe.expect(slept, atSleep: 1)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [slept], timeout: 5)
        XCTAssertEqual(machine.tableReads, 1)
        XCTAssertEqual(machine.tableReadsOnMain, 0)
        monitor.update(sessions: [])
    }
}
