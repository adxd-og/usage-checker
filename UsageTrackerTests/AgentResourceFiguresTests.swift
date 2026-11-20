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
            AgentResourceRules.figures(previous: nil, current: first),
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
        let figures = AgentResourceRules.figures(previous: first, current: second)
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
        XCTAssertEqual(AgentResourceRules.figures(previous: before, current: after).cpuPercent, 0)
    }

    func testReadingsTooFarApartGiveNoCPU() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 0))
        let late = try XCTUnwrap(reading(F.usageAt1, at: AgentResourceRules.maximumSpan + 1))
        let figures = AgentResourceRules.figures(previous: first, current: late)
        XCTAssertNil(figures.cpuPercent, "the Mac slept, or no session had a tty: start again")
        XCTAssertEqual(figures.memoryBytes, 2099 * F.mb)
        let atTheLimit = try XCTUnwrap(reading(F.usageAt1, at: AgentResourceRules.maximumSpan))
        XCTAssertNotNil(AgentResourceRules.figures(previous: first, current: atTheLimit).cpuPercent)
    }

    func testReadingsAtTheSameMomentOrOutOfOrderGiveNoCPU() throws {
        let first = try XCTUnwrap(reading(F.usageAt0, at: 5))
        let same = try XCTUnwrap(reading(F.usageAt1, at: 5))
        let earlier = try XCTUnwrap(reading(F.usageAt1, at: 0))
        XCTAssertNil(AgentResourceRules.figures(previous: first, current: same).cpuPercent)
        XCTAssertNil(AgentResourceRules.figures(previous: first, current: earlier).cpuPercent)
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

    // MARK: Outcome A (Task 1: a reaped child's time shows in its parent)
    // Each input has a process leave the tree, so outcome B's per-process body gives another
    // figure (170 % and 304 %) and fails these tests (review F5).

    func testAProcessThatExitedBetweenTwoReadingsCountsThroughItsParent() throws {
        let before = try XCTUnwrap(reading(F.usageAt1, at: 0))
        let after = try XCTUnwrap(reading(F.usageAt2Reaped, table: F.tableAfterClang, at: 5))
        let cpu = try XCTUnwrap(AgentResourceRules.figures(previous: before, current: after).cpuPercent)
        // Totals 4512.7 → 4516.7: 4.0 s in 5 s, clang's last 0.5 s through xcodebuild. Per process
        // it would be 1.0 + 5.5 + 2.0 = 8.5 s, 170 %: clang's earlier 4.5 s counted twice.
        XCTAssertEqual(cpu, 80, accuracy: 0.001)
    }

    func testAShortProcessBornAndReapedBetweenReadingsCountsOnce() throws {
        let before = try XCTUnwrap(reading(F.usageAt2Reaped, table: F.tableAfterClang, at: 0))
        let after = try XCTUnwrap(reading(F.usageAt3Reaped, table: F.tableAfterSwiftFrontend, at: 5))
        let cpu = try XCTUnwrap(AgentResourceRules.figures(previous: before, current: after).cpuPercent)
        // Totals 4516.7 → 4518.3: the compiler's 1.2 s and swift-frontend's last 0.4 s, 1.6 s in
        // 5 s. Per process it would be xcodebuild's 15.2 s, 304 %.
        XCTAssertEqual(cpu, 32, accuracy: 0.001)
    }
}
