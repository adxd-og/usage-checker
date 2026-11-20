import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Which processes, § Sampling: one snapshot of the process
/// table per sample answers for every session's tty; the reader is injected and time comes in
/// as `now:`. The sampler keeps each tty's last reading for the next CPU figure.
final class AgentResourceSamplerTests: XCTestCase {
    private typealias F = AgentProcessFixture

    func testOneReadOfTheTableServesEveryTTY() async {
        let machine = FakeMachine()
        let figures = await machine.sampler().sample(ttys: [F.tab, F.otherTab, F.pane], now: F.t0)
        XCTAssertEqual(machine.tableReads, 1)
        XCTAssertEqual(
            figures[F.tab],
            AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 1899 * F.mb, oldestStart: F.tabOpened)
        )
        XCTAssertEqual(
            figures[F.otherTab],
            AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 415 * F.mb, oldestStart: F.processStart), "2 + 410 + 3"
        )
        XCTAssertEqual(
            figures[F.pane],
            AgentResourceRules.Figures(cpuPercent: nil, memoryBytes: 525 * F.mb, oldestStart: F.processStart), "2 + 520 + 3"
        )
    }

    func testTheSecondSampleGivesCPU() async throws {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        _ = await sampler.sample(ttys: [F.tab], now: F.t0)
        machine.set(usage: F.usageAt1)
        let figures = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(5))
        let tab = try XCTUnwrap(figures[F.tab])
        let cpu = try XCTUnwrap(tab.cpuPercent)
        XCTAssertEqual(cpu, 232, accuracy: 0.001)
        XCTAssertEqual(tab.memoryBytes, 2099 * F.mb)
    }

    /// § Figures: a CPU figure is never above the Mac's cores × 100, and the sampler is told how
    /// many cores the Mac has: 11.6 s in 5 s is 232 % on ten cores and stops at 200 % on two.
    func testTheSamplerCapsItsFiguresAtTheCoreCountItWasGiven() async throws {
        func secondFigure(cores: Int) async throws -> Double {
            let machine = FakeMachine()
            let sampler = machine.sampler(cores: cores)
            _ = await sampler.sample(ttys: [F.tab], now: F.t0)
            machine.set(usage: F.usageAt1)
            let figures = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(5))
            return try XCTUnwrap(figures[F.tab]?.cpuPercent)
        }
        let onTen = try await secondFigure(cores: 10)
        XCTAssertEqual(onTen, 232, accuracy: 0.001)
        let onTwo = try await secondFigure(cores: 2)
        XCTAssertEqual(onTwo, 200)
    }

    func testASampleTooSoonAfterTheLastReadsNothingAndKeepsTheFigures() async {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        let first = await sampler.sample(ttys: [F.tab], now: F.t0)
        machine.set(usage: F.usageAt1)
        let again = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(1))
        XCTAssertEqual(machine.tableReads, 1)
        XCTAssertEqual(again, first)
    }

    func testATTYNoLongerAskedForIsForgotten() async {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        _ = await sampler.sample(ttys: [F.tab, F.otherTab], now: F.t0)
        let narrowed = await sampler.sample(ttys: [F.tab], now: F.t0.addingTimeInterval(5))
        XCTAssertEqual(Set(narrowed.keys), [F.tab])
        let widened = await sampler.sample(ttys: [F.tab, F.otherTab], now: F.t0.addingTimeInterval(10))
        XCTAssertNil(widened[F.otherTab]?.cpuPercent, "its first reading again: memory, no CPU yet")
        XCTAssertEqual(widened[F.otherTab]?.memoryBytes, 415 * F.mb)
        XCTAssertNotNil(widened[F.tab]?.cpuPercent)
    }

    func testATTYWhoseProcessesAreGoneHasNoFigures() async {
        let machine = FakeMachine()
        let sampler = machine.sampler()
        _ = await sampler.sample(ttys: [F.tab, F.otherTab], now: F.t0)
        machine.set(table: F.table.filter { $0.tty != F.otherTab })
        let figures = await sampler.sample(ttys: [F.tab, F.otherTab], now: F.t0.addingTimeInterval(5))
        XCTAssertNil(figures[F.otherTab])
        XCTAssertNotNil(figures[F.tab])
    }

    func testNoTTYReadsNothing() async {
        let machine = FakeMachine()
        let figures = await machine.sampler().sample(ttys: [], now: F.t0)
        XCTAssertEqual(figures, [:])
        XCTAssertEqual(machine.tableReads, 0)
    }
}
