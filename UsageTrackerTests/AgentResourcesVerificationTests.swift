import XCTest
@testable import Omelette

/// Parks the monitor's loop in its sleep and tells a test when the loop got there: records each
/// interval, fulfils the expectation registered for that many sleeps, then waits until the loop
/// is cancelled. No clock.
private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var waiting: [Int: XCTestExpectation] = [:]

    var intervals: [TimeInterval] { lock.withLock { recorded } }

    func expect(_ expectation: XCTestExpectation, atSleep count: Int) {
        lock.withLock { waiting[count] = expectation }
    }

    func sleep(_ seconds: TimeInterval) async {
        let reached: XCTestExpectation? = lock.withLock {
            recorded.append(seconds)
            return waiting.removeValue(forKey: recorded.count)
        }
        reached?.fulfill()
        _ = try? await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

/// Verification of spec 2026-11-19 agent resources, written from the spec and not from the
/// implementer's tests: § Which processes (the member walk across a detached or root-owned link,
/// a cycle, a self-parented row, a reused tty and two sessions on one tty end to end through the
/// monitor), § Figures (absurd counters), § Sampling (the sampler's own span rules, a surface
/// held before any session is live, a changed tty set), § Wire format (nothing but the two keys
/// differs, the scale switch never reaches the file, a newer session taking a tty reaches the
/// file at once) and § Where it shows (the CPU order's action rows and the sort switch).
final class AgentResourcesVerificationTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private typealias Figures = AgentResourceRules.Figures

    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    private func session(
        _ id: String, tty: String?, state: AgentState = .working, lastEventAt: Date = AgentProcessFixture.t0
    ) -> AgentSession {
        Fixture.agentSession(
            sessionID: id, state: state, stateSince: lastEventAt, lastEventAt: lastEventAt,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: tty)
        )
    }

    // MARK: Which processes

    /// § Which processes: a process that detached and was re-parented to launchd is not counted,
    /// and nothing below it is either: its children hang off a process outside the tree.
    func testADaemonReparentedToLaunchdTakesItsWholeSubtreeOutOfTheSession() {
        let tty = "/dev/ttys021"
        let table = [
            F.row(1100, 400, tty),   // the agent
            F.row(1101, 1100, nil),  // its Bash tool's shell
            F.row(1102, 1, nil),     // a daemon the shell started: launchd's now
            F.row(1103, 1102, nil),  // the daemon's worker
        ]
        XCTAssertEqual(AgentResourceRules.members(of: tty, in: table), [1100, 1101])
    }

    func testASelfParentedRowIsCountedOnceAndWalksNowhere() {
        let tty = "/dev/ttys022"
        let table = [F.row(1200, 1200, tty), F.row(1201, 1200, nil)]
        XCTAssertEqual(AgentResourceRules.members(of: tty, in: table), [1200, 1201])
    }

    /// A table read mid-change can hold a cycle. One the tty touches is walked once; one nothing
    /// on the tty reaches stays out.
    func testACycleTheTTYTouchesIsWalkedOnceAndAnotherCycleStaysOut() {
        let tty = "/dev/ttys023"
        let table = [
            F.row(810, 811, tty), F.row(811, 810, nil), F.row(812, 811, nil),
            F.row(820, 821, nil), F.row(821, 820, nil),
        ]
        XCTAssertEqual(AgentResourceRules.members(of: tty, in: table), [810, 811, 812])
    }

    func testAVeryDeepChainIsWalkedToItsEndWithoutRecursion() {
        let tty = "/dev/ttys024"
        let depth: pid_t = 20_000
        var table = [F.row(5000, 400, tty)]
        for offset in 1...depth {
            table.append(F.row(5000 + offset, 4999 + offset, nil))
        }
        XCTAssertEqual(AgentResourceRules.members(of: tty, in: table).count, Int(depth) + 1)
    }

    /// `sysctl` answers in pid order, but a table read mid-change need not: the walk must not
    /// depend on where a child sits relative to its parent.
    func testTheMembersDoNotDependOnTheOrderOfTheTable() {
        let expected = AgentResourceRules.members(of: F.tab, in: F.table)
        XCTAssertEqual(AgentResourceRules.members(of: F.tab, in: F.table.reversed()), expected)
        let rotated = Array(F.table.dropFirst(7)) + F.table.prefix(7)
        XCTAssertEqual(AgentResourceRules.members(of: F.tab, in: rotated), expected)
    }

    /// § Which processes: root's `login` is the first process of every Terminal tab and
    /// `proc_pid_rusage` refuses it; a root-owned `sudo` in the middle of a chain is refused the
    /// same. The walk crosses both: what hangs below is the session's and is measured.
    func testAProcessBelowARootOwnedLinkIsStillMeasured() throws {
        let tty = "/dev/ttys025"
        let table = [
            F.row(1000, 400, tty),   // the agent
            F.row(1001, 1000, nil),  // sudo, root's
            F.row(1002, 1001, nil),  // the build under it, the user's
        ]
        let usage: [pid_t: AgentResourceRules.Usage] = [
            1000: F.usage(1, 10), 1002: F.usage(5, 100),
        ]
        let read = try XCTUnwrap(AgentResourceRules.reading(of: tty, in: table, usage: { usage[$0] }, at: F.t0))
        XCTAssertEqual(read.cpuSeconds.keys.sorted(), [1000, 1002], "sudo (1001) is refused and skipped")
        XCTAssertEqual(read.footprintBytes, 110 * F.mb)

        let onlyTheBuild = try XCTUnwrap(AgentResourceRules.reading(
            of: tty, in: table, usage: { $0 == 1002 ? F.usage(5, 100) : nil }, at: F.t0
        ), "even when every process on the tty itself is refused")
        XCTAssertEqual(onlyTheBuild.footprintBytes, 100 * F.mb)
    }

    /// § Which processes: of several live sessions on one tty only the most recently active one
    /// gets the figures, a tie to the smaller id, whatever order the store lists them in.
    func testTheOwnerOfASharedTTYDoesNotDependOnTheListsOrder() {
        let newest = session("m", tty: F.tab, lastEventAt: F.t0)
        let tiedLater = session("z", tty: F.tab, lastEventAt: F.t0)
        let older = session("a", tty: F.tab, lastEventAt: F.t0.addingTimeInterval(-60))
        let all = [newest, tiedLater, older]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            XCTAssertEqual(
                AgentResourceRules.owners(of: order.map { all[$0] }), [newest.id: F.tab],
                "list order \(order): the tie between m and z goes to m, and the older a is never the owner"
            )
        }
    }

    /// § Which processes, end to end through the monitor and an injected machine: the figures
    /// reach the session that owns its tty and only that one.
    @MainActor
    func testTheMonitorGivesFiguresToTheOwnerOfATTYAndNotToAGhostOrAnOlderSession() async {
        let machine = FakeMachine()
        let sleeps = Sleeps()
        let monitor = AgentResourceMonitor(sampler: machine.sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) })
        let slept = expectation(description: "the first sample was published")
        sleeps.expect(slept, atSleep: 1)

        let own = session("own", tty: F.tab, lastEventAt: F.t0)
        // The second tab's every process started an hour before t0; this session's last event is
        // two and a half hours old: its tab closed and a newer one got the device name.
        let ghost = session("ghost", tty: F.otherTab, lastEventAt: F.t0.addingTimeInterval(-9000))
        let paneOld = session("pane-old", tty: F.pane, lastEventAt: F.t0.addingTimeInterval(-60))
        let paneNew = session("pane-new", tty: F.pane, lastEventAt: F.t0)
        let panel = session("panel", tty: nil)
        monitor.update(sessions: [own, ghost, paneOld, paneNew, panel])
        await fulfillment(of: [slept], timeout: 5)

        XCTAssertEqual(Set(monitor.byTTY.keys), [F.tab, F.otherTab, F.pane], "every tty is read once")
        XCTAssertEqual(Set(monitor.bySession.keys), [own.id, paneNew.id])
        XCTAssertEqual(monitor.bySession[own.id]?.memoryBytes, 1899 * F.mb)
        XCTAssertEqual(monitor.bySession[paneNew.id]?.memoryBytes, 525 * F.mb)
        XCTAssertEqual(machine.tableReads, 1, "one snapshot of the table answers for every session")
        monitor.update(sessions: [])
    }

    // MARK: Figures

    /// § Figures: a published figure is never non-finite. Two readings whose sums overflow a
    /// Double are absurd, but the rule still hands out a finite figure or none.
    func testCounterSumsBeyondADoubleNeverMakeANonFiniteCPU() throws {
        let huge = AgentResourceRules.Usage(cpuSeconds: 1.7e308, footprintBytes: F.mb)
        let none = AgentResourceRules.Usage(cpuSeconds: 0, footprintBytes: F.mb)
        let before = try XCTUnwrap(AgentResourceRules.reading(of: F.tab, in: F.table, usage: { _ in none }, at: F.t0))
        let after = try XCTUnwrap(AgentResourceRules.reading(
            of: F.tab, in: F.table, usage: { _ in huge }, at: F.t0.addingTimeInterval(5)
        ))
        if let cpu = AgentResourceRules.cpuPercent(previous: before, current: after) {
            XCTAssertTrue(cpu.isFinite, "got \(cpu)")
            XCTAssertGreaterThanOrEqual(cpu, 0)
        }
    }

    // MARK: Sampling

    /// The sampler reads a tty again from two seconds on and not before; a clock that went back
    /// reads at once and shows no CPU for that pair.
    func testTheSamplerReadsAgainAtTwoSecondsNotBeforeAndAClockGoingBackReadsAtOnce() async throws {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        _ = await sampler.sample(ttys: [F.tab], now: F.t0)
        machine.set(usage: F.usageAt1)
        _ = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(1.999))
        XCTAssertEqual(machine.tableReads, 1, "1.999 s: still its own reading")
        let atTwo = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(2))
        XCTAssertEqual(machine.tableReads, 2, "two seconds: read")
        let cpu = try XCTUnwrap(atTwo[F.tab]?.cpuPercent)
        XCTAssertEqual(cpu, 580, accuracy: 0.001, "11.6 s in 2 s")

        let back = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(-30))
        XCTAssertEqual(machine.tableReads, 3, "a clock that went back reads at once")
        XCTAssertNil(back[F.tab]?.cpuPercent, "a span below zero is no pair")
        XCTAssertNotNil(back[F.tab]?.memoryBytes)
    }

    /// A tty that joins the set is read and the ones already read keep their figures untouched:
    /// recomputing them over a sliver of a second would print an absurd CPU.
    func testATTYJoiningTheSetIsReadAloneAndTheOthersKeepTheirFigures() async {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        let first = await sampler.sample(ttys: [F.tab], now: F.t0)
        machine.set(usage: F.usageAt1)
        let both = await sampler.sample(ttys: [F.tab, F.pane], now: F.t0.addingTimeInterval(1))
        XCTAssertEqual(machine.tableReads, 2)
        XCTAssertEqual(both[F.tab], first[F.tab], "read 1 s ago: its figures stand, no CPU over a sliver")
        XCTAssertEqual(both[F.pane]?.memoryBytes, 525 * F.mb)
        XCTAssertNil(both[F.pane]?.cpuPercent, "its first reading")
    }

    /// § Sampling: the 5 s cadence belongs to the surface, not to the session list. A view that is
    /// on screen before any session is live holds the surface; the first session that has a tty
    /// is sampled at 5 s at once, and the same after every gap with no tty.
    @MainActor
    func testASurfaceHeldBeforeAnySessionIsLiveSetsTheCadenceOfTheFirstOne() async {
        let sleeps = Sleeps()
        let monitor = AgentResourceMonitor(sampler: FakeMachine().sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) })
        let view = UUID()
        monitor.setWatching(.agentsTab, by: view, true)
        XCTAssertNil(monitor.cadence, "no session, nothing to sample")
        XCTAssertFalse(monitor.isSampling)

        let first = expectation(description: "first loop sleeps")
        sleeps.expect(first, atSleep: 1)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(sleeps.intervals, [5])

        monitor.update(sessions: [session("ide", tty: nil)])
        XCTAssertNil(monitor.cadence)
        let again = expectation(description: "the loop after the gap sleeps")
        sleeps.expect(again, atSleep: 2)
        monitor.update(sessions: [session("b", tty: F.pane)])
        await fulfillment(of: [again], timeout: 5)
        XCTAssertEqual(sleeps.intervals, [5, 5], "the view never left: still the fast cadence")
        monitor.update(sessions: [])
    }

    /// A new tty in the set restarts the loop with a sample at once, so the new session shows
    /// memory without waiting a whole cadence.
    @MainActor
    func testANewTTYInTheSetIsSampledAtOnceAndNotAtTheNextTick() async {
        let machine = FakeMachine()
        let sleeps = Sleeps()
        let monitor = AgentResourceMonitor(sampler: machine.sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) })
        let first = expectation(description: "first loop sleeps")
        let second = expectation(description: "the restarted loop sleeps")
        sleeps.expect(first, atSleep: 1)
        sleeps.expect(second, atSleep: 2)
        let a = session("a", tty: F.tab)
        monitor.update(sessions: [a])
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(Set(monitor.bySession.keys), [a.id])

        let b = session("b", tty: F.pane)
        monitor.update(sessions: [a, b])
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(sleeps.intervals, [30, 30])
        XCTAssertEqual(Set(monitor.bySession.keys), [a.id, b.id], "the new tab's memory is there already")
        XCTAssertEqual(monitor.bySession[b.id]?.memoryBytes, 525 * F.mb)
        monitor.update(sessions: [])
    }

    /// § Sampling: a second surface opening while one is already open, and one closing while the
    /// other stays, change nothing about the loop: the watched state as a whole did not change,
    /// so no loop is replaced and no sample is taken. The one wait is an inverted expectation: it
    /// passes when the replaced loop's sleep never arrives.
    @MainActor
    func testASurfaceComingAndGoingWhileAnotherHoldsTheCadenceLeavesTheLoopAlone() async {
        let sleeps = Sleeps()
        let monitor = AgentResourceMonitor(sampler: FakeMachine().sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) })
        let first = expectation(description: "the 30 s loop sleeps")
        let fast = expectation(description: "the 5 s loop sleeps")
        sleeps.expect(first, atSleep: 1)
        sleeps.expect(fast, atSleep: 2)
        monitor.update(sessions: [session("a", tty: F.tab)])
        await fulfillment(of: [first], timeout: 5)
        let island = UUID(), tab = UUID()
        monitor.setWatching(.island, by: island, true)
        await fulfillment(of: [fast], timeout: 5)

        let replaced = expectation(description: "a loop that nothing asked for sleeps")
        replaced.isInverted = true
        sleeps.expect(replaced, atSleep: 3)
        monitor.setWatching(.agentsTab, by: tab, true)
        monitor.setWatching(.island, by: island, false)
        monitor.setWatching(.island, by: island, true)
        await fulfillment(of: [replaced], timeout: 0.3)
        XCTAssertEqual(sleeps.intervals, [30, 5])
        monitor.update(sessions: [])
    }

    /// § Sampling: the loop restarts when the set of ttys changes, not when the session list does.
    /// A newer session on a tty already read, or a session changing state, is no new loop.
    @MainActor
    func testAChangeOfTheSessionListThatKeepsTheTTYsLeavesTheLoopAlone() async {
        let sleeps = Sleeps()
        let monitor = AgentResourceMonitor(sampler: FakeMachine().sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) })
        let first = expectation(description: "the loop sleeps")
        sleeps.expect(first, atSleep: 1)
        let a = session("a", tty: F.tab, lastEventAt: F.t0.addingTimeInterval(-60))
        monitor.update(sessions: [a])
        await fulfillment(of: [first], timeout: 5)

        let replaced = expectation(description: "a loop that nothing asked for sleeps")
        replaced.isInverted = true
        sleeps.expect(replaced, atSleep: 2)
        monitor.update(sessions: [a, session("b", tty: F.tab, lastEventAt: F.t0)])
        monitor.update(sessions: [session("b", tty: F.tab, state: .idle, lastEventAt: F.t0)])
        await fulfillment(of: [replaced], timeout: 0.3)
        XCTAssertEqual(sleeps.intervals, [30])
        monitor.update(sessions: [])
    }

    /// § Sampling, § Wire format: the 30 s readings of an unwatched app have to give a CPU too,
    /// or the file would never carry one. A pair 30 s apart is a pair; one an hour apart, after
    /// a sleep, is not.
    func testReadingsAtTheUnwatchedCadenceGiveCPUAndAnHourApartDoNot() throws {
        func figures(secondsApart: TimeInterval) throws -> Figures {
            let first = try XCTUnwrap(AgentResourceRules.reading(of: F.tab, in: F.table, usage: { F.usageAt0[$0] }, at: F.t0))
            let second = try XCTUnwrap(AgentResourceRules.reading(
                of: F.tab, in: F.table, usage: { F.usageAt1[$0] }, at: F.t0.addingTimeInterval(secondsApart)
            ))
            return AgentResourceRules.figures(previous: first, current: second)
        }
        let thirty = try XCTUnwrap(try figures(secondsApart: AgentResourceRules.unwatchedInterval).cpuPercent)
        XCTAssertEqual(thirty, 11.6 / 30 * 100, accuracy: 0.001)
        XCTAssertNil(try figures(secondsApart: 3600).cpuPercent)
    }

    // MARK: Wire format

    /// § Wire format: no existing field changes. The file built with figures and the file built
    /// without them differ in exactly the two new keys on the measured sessions, services and
    /// counts included; a reader that only knows the old keys decodes the new file.
    func testTheFigureKeysAreTheOnlyDifferenceInTheFile() throws {
        let now = F.t0
        let live = [
            Fixture.agentSession(
                sessionID: "a", projectName: "Usage tracker", state: .needsYou, activity: "Bash: xcodebuild",
                host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
            ),
            Fixture.agentSession(
                sessionID: "b", projectName: "Orion", state: .working,
                host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.otherTab)
            ),
            Fixture.agentSession(sessionID: "c", projectName: "Panel", state: .idle),
        ]
        let services = [Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Session", percent: 42, resetsAt: now.addingTimeInterval(3600), kind: .session)],
            weekCost: 12, at: now
        )]
        let costs = ["claude": StatusFileWriter.CostEntry(todayCost: 4.2, weekCost: 31.7, todayTokens: 1_234_567)]
        let measured = AgentResourceRules.bySession(live, byTTY: [
            F.tab: Figures(cpuPercent: 212.34, memoryBytes: 2099 * F.mb),
            F.otherTab: Figures(cpuPercent: nil, memoryBytes: 634 * F.mb),
        ])
        XCTAssertEqual(Set(measured.keys), [live[0].id, live[1].id])

        func object(resources: [String: Figures]) throws -> [String: Any] {
            let snapshot = StatusFileWriter.build(
                services: services, costs: costs,
                agents: StatusFileWriter.AgentSummary(sessions: live), resources: resources, now: now
            )
            let data = try StatusFile.encoder.encode(snapshot)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let without = try object(resources: [:])
        var with = try object(resources: measured)
        var agents = try XCTUnwrap(with["agents"] as? [String: Any])
        var sessions = try XCTUnwrap(agents["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.compactMap { $0["memoryBytes"] }.count, 2)
        XCTAssertEqual(sessions.compactMap { $0["cpuPercent"] }.count, 1)
        sessions = sessions.map { var s = $0; s["memoryBytes"] = nil; s["cpuPercent"] = nil; return s }
        agents["sessions"] = sessions
        with["agents"] = agents
        XCTAssertEqual(NSDictionary(dictionary: with), NSDictionary(dictionary: without))
        XCTAssertEqual(with["version"] as? Int, 2)

        struct OldShape: Decodable {
            struct Agents: Decodable {
                struct Session: Decodable { let id: String; let project: String; let state: String; let activity: String? }
                let needsYou: Int
                let working: Int
                let sessions: [Session]
            }
            let version: Int
            let agents: Agents
        }
        let data = try StatusFile.encoder.encode(StatusFileWriter.build(
            services: services, costs: costs,
            agents: StatusFileWriter.AgentSummary(sessions: live), resources: measured, now: now
        ))
        let old = try JSONDecoder().decode(OldShape.self, from: data)
        XCTAssertEqual(old.agents.sessions.map(\.id), live.map(\.id))
        XCTAssertEqual(old.agents.sessions.first?.activity, "Bash: xcodebuild")
    }

    /// Decision 2: the switch changes what the island and the Agents tab print; the wire's
    /// `cpuPercent` stays per core, so it has one meaning.
    @MainActor
    func testTheWholeMacSwitchNeverReachesTheFile() throws {
        let live = [Fixture.agentSession(sessionID: "a", host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab))]
        let resources = AgentResourceRules.bySession(live, byTTY: [F.tab: Figures(cpuPercent: 212.34, memoryBytes: 2099 * F.mb)])
        func cpuInTheFile() -> Double? {
            StatusFileWriter.build(
                services: [], costs: [:], agents: StatusFileWriter.AgentSummary(sessions: live),
                resources: resources, now: F.t0
            ).agents.sessions.first?.cpuPercent
        }
        let settings = SettingsStore.shared
        defer { settings.agentsCPUScale = .perCore }
        settings.agentsCPUScale = .perCore
        XCTAssertEqual(cpuInTheFile(), 212.3)
        settings.agentsCPUScale = .wholeMac
        XCTAssertEqual(cpuInTheFile(), 212.3, "still per core on the Whole Mac scale")
        XCTAssertEqual(AgentResourceCopy.cpuText(perCore: 212.34, scale: settings.agentsCPUScale, cores: 10), "21%")
    }

    /// § Sampling: a session that gains or loses its figures reaches the file at once. A newer
    /// session taking over a tty loses the old one's and gains its own in the same moment: the
    /// same number of sessions with figures, a different set. The file must not show one tree on
    /// both for half a minute.
    func testANewerSessionTakingTheTTYReachesTheFileAtOnceThoughTheCountIsTheSame() {
        let old = ["claude:old": Figures(cpuPercent: 10, memoryBytes: 634 * F.mb)]
        let new = ["claude:new": Figures(cpuPercent: 10, memoryBytes: 634 * F.mb)]
        XCTAssertTrue(AgentResourceRules.publishesToFile(
            new, over: old, lastAt: F.t0, now: F.t0.addingTimeInterval(1)
        ))
        XCTAssertFalse(AgentResourceRules.publishesToFile(
            old, over: old, lastAt: F.t0, now: F.t0.addingTimeInterval(1)
        ), "the same sessions, new numbers one second later: the views only")
    }

    // MARK: Where it shows

    /// § Where it shows: rows that carry an action keep the top — a permission request held on a
    /// row whose state reads Working included. Here the held row is the older one and has the
    /// lower CPU; it still leads.
    func testARowHoldingAllowAndDenyKeepsTheTopUnderTheCPUSortWhateverItsState() {
        var held = Fixture.agentSession(
            sessionID: "held", projectName: "held", state: .working,
            stateSince: F.t0.addingTimeInterval(-600), lastEventAt: F.t0.addingTimeInterval(-600),
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        )
        held.pendingPermissionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
        XCTAssertTrue(AgentRowText.carriesAction(held))
        let busy = session("busy", tty: F.pane)
        let figures = AgentResourceRules.bySession([held, busy], byTTY: [
            F.tab: Figures(cpuPercent: 1, memoryBytes: 100 * F.mb),
            F.pane: Figures(cpuPercent: 300, memoryBytes: 100 * F.mb),
        ])
        XCTAssertEqual(AgentsLiveCard.rows([held, busy], sort: .state, figures: figures).map(\.sessionID), ["busy", "held"])
        XCTAssertEqual(AgentsLiveCard.rows([held, busy], sort: .cpu, figures: figures).map(\.sessionID), ["held", "busy"])
    }

    /// The CPU order is a function of the figures and the state order, not of the order the store
    /// happens to list the sessions in: three rows that print the same percent keep the state
    /// order whichever way they arrive.
    func testTheCPUOrderDoesNotDependOnTheOrderTheSessionsArriveIn() {
        let ids = ["a", "b", "c", "d"]
        let ttys = [F.tab, F.otherTab, F.pane, F.otherPane]
        let live = ids.enumerated().map { index, id in
            Fixture.agentSession(
                sessionID: id, projectName: id, state: .working,
                stateSince: F.t0.addingTimeInterval(-Double(index) * 60),
                lastEventAt: F.t0.addingTimeInterval(-Double(index) * 60),
                host: AgentHostInfo(pid: nil, bundleID: nil, tty: ttys[index])
            )
        }
        // a (newest), b, c, d (oldest) in state order. c is the busiest; a, b and d print 7%.
        let figures = AgentResourceRules.bySession(live, byTTY: [
            F.tab: Figures(cpuPercent: 7.2, memoryBytes: F.mb),
            F.otherTab: Figures(cpuPercent: 7.0, memoryBytes: F.mb),
            F.pane: Figures(cpuPercent: 90, memoryBytes: F.mb),
            F.otherPane: Figures(cpuPercent: 6.8, memoryBytes: F.mb),
        ])
        let expected = ["c", "a", "b", "d"]
        XCTAssertEqual(AgentsLiveCard.rows(live, sort: .cpu, figures: figures).map(\.sessionID), expected)
        XCTAssertEqual(AgentsLiveCard.rows(live.reversed(), sort: .cpu, figures: figures).map(\.sessionID), expected)
        XCTAssertEqual(AgentsLiveCard.rows([live[2], live[0], live[3], live[1]], sort: .cpu, figures: figures).map(\.sessionID), expected)
    }

    /// § Where it shows: the switch is for two sessions up when at least one *listed* session has
    /// figures. Figures kept for a session the card does not list (another source's, filtered
    /// out) do not make it appear.
    func testTheSortSwitchIgnoresFiguresOfSessionsTheCardDoesNotList() {
        let listed = [session("a", tty: nil), session("b", tty: nil)]
        let unlisted = session("elsewhere", tty: F.tab)
        let figures = AgentResourceRules.bySession([unlisted], byTTY: [F.tab: Figures(cpuPercent: 5, memoryBytes: F.mb)])
        XCTAssertEqual(Set(figures.keys), [unlisted.id])
        XCTAssertFalse(AgentsLiveCard.showsSort(listed, figures: figures))
    }
}
