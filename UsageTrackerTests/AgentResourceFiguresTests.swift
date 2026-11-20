import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Figures: CPU as Activity Monitor counts it (100 % is one
/// core), the time the session's processes gained between two readings over the time between
/// them; memory the sum of the physical footprints. A first reading shows memory and no CPU; a
/// total that went down gives 0 %, never a negative figure; another user's process is skipped.
final class AgentResourceFiguresTests: XCTestCase {
    private typealias F = AgentProcessFixture

    private func reading(
        _ usage: [pid_t: AgentResourceRules.Usage],
        table: [AgentResourceRules.ProcessRow] = AgentProcessFixture.table,
        at seconds: TimeInterval
    ) -> AgentResourceRules.Reading? {
        AgentResourceRules.reading(
            of: F.tab, in: table, usage: { usage[$0] }, at: F.t0.addingTimeInterval(seconds)
        )
    }

    func testTheFirstReadingShowsMemoryAndNoCPUYet() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        XCTAssertEqual(
            AgentResourceRules.figures(previous: nil, current: first, cores: AgentProcessFixture.cores),
            AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 1899 * F.mb, oldestStart: F.tabOpened),
            "2 + 634 + 90 + 20 + 3 + 300 + 150 + 700 MB"
        )
    }

    /// § Which processes (review F4): a reading dates its tty by its oldest process, root's
    /// `login` included though `proc_pid_rusage` refuses it — the table answers for every pid.
    func testAReadingKnowsWhenItsOldestProcessStarted() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        XCTAssertEqual(first.oldestStart, F.tabOpened)
        let withoutLogin = try XCTUnwrap(reading(F.usageAt0, table: F.table.filter { $0.pid != 500 }, at: 0))
        XCTAssertEqual(withoutLogin.oldestStart, F.processStart)
    }

    func testCPUIsTheTimeGainedOverTheTimeBetweenWithOneCoreAt100() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        let second = try XCTUnwrap(reading(F.usageAt1, at: 5))
        let figures = AgentResourceRules.figures(previous: first, current: second, cores: AgentProcessFixture.cores)
        let cpu = try XCTUnwrap(figures.cpuPercent)
        XCTAssertEqual(cpu, 232, accuracy: 0.001, "11.6 s in 5 s")
        XCTAssertEqual(figures.memoryBytes, 2099 * F.mb)
    }

    func testAnotherUsersProcessIsSkipped() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        XCTAssertEqual(
            first.cpuSeconds.keys.sorted(), [501, 502, 503, 504, 510, 511, 512, 513],
            "root's login (500) refuses proc_pid_rusage"
        )
    }

    func testATTYWhoseProcessesAllRefuseHasNoReading() {
        XCTAssertNil(reading([:], at: 0))
    }

    func testATTYNoProcessHoldsHasNoReading() {
        XCTAssertNil(AgentResourceRules.reading(
            of: F.closedTab, in: F.table, usage: { F.usageAt0[$0] }, at: F.t0
        ))
    }

    func testATotalThatWentDownGivesZeroNeverANegativeFigure() throws {
        let before = try XCTUnwrap(reading(F.usageAt1, at: 0))
        // claude (502) quit: its MCP servers keep the tty, its Bash tool's shell and the build
        // no longer hang below a member.
        let after = try XCTUnwrap(reading(F.usageAt1, table: F.table.filter { $0.pid != 502 }, at: 5))
        XCTAssertEqual(AgentResourceRules.figures(previous: before, current: after, cores: AgentProcessFixture.cores).cpuPercent, 0)
    }

    func testReadingsTooFarApartGiveNoCPU() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        let late = try XCTUnwrap(reading(F.usageAt1, at: AgentResourceRules.maximumSpan + 1))
        let figures = AgentResourceRules.figures(previous: first, current: late, cores: AgentProcessFixture.cores)
        XCTAssertNil(figures.cpuPercent, "the Mac slept, or no session had a tty: start again")
        XCTAssertEqual(figures.memoryBytes, 2099 * F.mb)
        let atTheLimit = try XCTUnwrap(reading(F.usageAt1, at: AgentResourceRules.maximumSpan))
        XCTAssertNotNil(AgentResourceRules.figures(previous: first, current: atTheLimit, cores: AgentProcessFixture.cores).cpuPercent)
    }

    func testReadingsAtTheSameMomentOrOutOfOrderGiveNoCPU() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 5))
        let same = try XCTUnwrap(reading(F.usageAt1, at: 5))
        let earlier = try XCTUnwrap(reading(F.usageAt1, at: 0))
        XCTAssertNil(AgentResourceRules.figures(previous: first, current: same, cores: AgentProcessFixture.cores).cpuPercent)
        XCTAssertNil(AgentResourceRules.figures(previous: first, current: earlier, cores: AgentProcessFixture.cores).cpuPercent)
    }

    func testAnExtremeCounterNeverTraps() throws {
        let extreme: [pid_t: AgentResourceRules.Usage] = [
            501: AgentResourceRules.Usage(cpuSeconds: -5, footprintBytes: Int.max),
            502: AgentResourceRules.Usage(cpuSeconds: 10, footprintBytes: Int.max),
            503: AgentResourceRules.Usage(cpuSeconds: .nan, footprintBytes: -1),
        ]
        let read = try XCTUnwrap(reading(extreme, at: 0))
        XCTAssertEqual(read.footprintBytes, Int.max)
        XCTAssertEqual(read.cpuSeconds[501], 0)
        XCTAssertEqual(read.cpuSeconds[503], 0)
    }

    // MARK: The ceiling: never above every core, never non-finite

    /// Two hand-built readings of one tty, `span` seconds apart, whose members gained `seconds`.
    private func pair(
        from before: [pid_t: Double], gaining seconds: Double, over span: TimeInterval
    ) -> (AgentResourceRules.Reading, AgentResourceRules.Reading) {
        var after = before
        after[501, default: 0] += seconds
        return (
            AgentResourceRules.Reading(at: F.t0, cpuSeconds: before, footprintBytes: F.mb, oldestStart: nil),
            AgentResourceRules.Reading(
                at: F.t0.addingTimeInterval(span), cpuSeconds: after, footprintBytes: F.mb, oldestStart: nil
            )
        )
    }

    private func cpu(gaining seconds: Double, over span: TimeInterval, cores: Int) -> Double? {
        let (before, after) = pair(from: [501: 100, 502: 40], gaining: seconds, over: span)
        return AgentResourceRules.cpuPercent(previous: before, current: after, cores: cores)
    }

    /// A child the app cannot read (root's, under `sudo`) that a readable parent reaps moves its
    /// whole lifetime into one span: more than every core for the whole span is that, and the
    /// figure stops at cores × 100.
    func testAFigureAboveEveryCoreStopsAtTheCoresTimes100() throws {
        XCTAssertEqual(cpu(gaining: 60, over: 5, cores: 10), 1000, "60 s in 5 s on 10 cores: 1000, not 1200")
        XCTAssertEqual(cpu(gaining: 600, over: 5, cores: 10), 1000, "a reaped child's lifetime in one span")
        XCTAssertEqual(cpu(gaining: 50, over: 5, cores: 10), 1000, "every core for the whole span stays")
        let below = try XCTUnwrap(cpu(gaining: 49, over: 5, cores: 10))
        XCTAssertEqual(below, 980, accuracy: 0.001, "below the ceiling: as measured")
        let wider = try XCTUnwrap(cpu(gaining: 60, over: 5, cores: 18))
        XCTAssertEqual(wider, 1200, accuracy: 0.001, "18 cores can run 1200 %")
    }

    func testACoreCountBelowOneCountsAsOneCore() throws {
        XCTAssertEqual(cpu(gaining: 60, over: 5, cores: 0), 100)
        XCTAssertEqual(cpu(gaining: 60, over: 5, cores: -4), 100)
        let below = try XCTUnwrap(cpu(gaining: 2, over: 5, cores: 0))
        XCTAssertEqual(below, 40, accuracy: 0.001, "below one core: as measured")
    }

    /// Finite counters can add up to infinity, and two infinite totals subtract to NaN: neither
    /// is a figure.
    func testCounterSumsThatOverflowGiveNoCPUFigure() {
        let huge = Double.greatestFiniteMagnitude
        func reading(at seconds: TimeInterval, _ counters: [pid_t: Double]) -> AgentResourceRules.Reading {
            AgentResourceRules.Reading(
                at: F.t0.addingTimeInterval(seconds), cpuSeconds: counters, footprintBytes: F.mb, oldestStart: nil
            )
        }
        func cpu(_ before: [pid_t: Double], _ after: [pid_t: Double]) -> Double? {
            AgentResourceRules.cpuPercent(previous: reading(at: 0, before), current: reading(at: 5, after), cores: 10)
        }
        XCTAssertNil(cpu([501: 0, 502: 0], [501: huge, 502: huge]), "the newer sum overflows")
        XCTAssertNil(cpu([501: huge, 502: huge], [501: huge, 502: huge]), "both overflow: infinity minus infinity")
        XCTAssertNil(cpu([501: huge, 502: huge], [501: 0, 502: 0]), "the older sum overflows")
    }

    /// A finite gain over a span short enough that the quotient overflows is no figure either.
    func testAGainWhoseQuotientOverflowsGivesNoCPUFigure() {
        let (before, after) = pair(from: [501: 0], gaining: 1e306, over: 0.001)
        XCTAssertGreaterThan(after.at.timeIntervalSince(before.at), 0, "a real span, not the same moment")
        XCTAssertNil(AgentResourceRules.cpuPercent(previous: before, current: after, cores: 10))
    }

    // MARK: Outcome A (Task 1: a reaped child's time shows in its parent)
    // Each input has a process leave the tree, so outcome B's per-process body gives another
    // figure (170 % and 304 %) and fails these tests (review F5).

    func testAProcessThatExitedBetweenTwoReadingsCountsThroughItsParent() throws {
        let before = try XCTUnwrap(reading(F.usageAt1, at: 0))
        let after = try XCTUnwrap(reading(F.usageAt2Reaped, table: F.tableAfterClang, at: 5))
        let cpu = try XCTUnwrap(AgentResourceRules.figures(previous: before, current: after, cores: AgentProcessFixture.cores).cpuPercent)
        // Totals 4512.7 → 4516.7: 4.0 s in 5 s, clang's last 0.5 s through xcodebuild. Per process
        // it would be 1.0 + 5.5 + 2.0 = 8.5 s, 170 %: clang's earlier 4.5 s counted twice.
        XCTAssertEqual(cpu, 80, accuracy: 0.001)
    }

    func testAShortProcessBornAndReapedBetweenReadingsCountsOnce() throws {
        let before = try XCTUnwrap(reading(F.usageAt2Reaped, table: F.tableAfterClang, at: 0))
        let after = try XCTUnwrap(reading(F.usageAt3Reaped, table: F.tableAfterSwiftFrontend, at: 5))
        let cpu = try XCTUnwrap(AgentResourceRules.figures(previous: before, current: after, cores: AgentProcessFixture.cores).cpuPercent)
        // Totals 4516.7 → 4518.3: the compiler's 1.2 s and swift-frontend's last 0.4 s, 1.6 s in
        // 5 s. Per process it would be xcodebuild's 15.2 s, 304 %.
        XCTAssertEqual(cpu, 32, accuracy: 0.001)
    }
}
