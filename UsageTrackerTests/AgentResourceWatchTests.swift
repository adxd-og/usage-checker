import AppKit
import SwiftUI
import XCTest
@testable import Omelette

/// Stands in for the monitor's sleep: records each interval, fulfils the expectation waiting on
/// that many sleeps, then parks until the loop that called it is cancelled. Every restart of the
/// monitor's loop ends in one sleep, so the count says when a view's word has reached it.
private final class LoopSleeps: @unchecked Sendable {
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
        let (parked, wake) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in parked {}
        } onCancel: {
            wake.finish()
        }
    }
}

/// Spec 2026-11-19 agent resources § Sampling: every 5 s while the island or the Agents tab is
/// open, every 30 s otherwise, a surface counting as open per view instance. Each view's watch
/// (`PopoverView.ResourceWatch`, `AgentsHistoryView.ResourceWatch`) runs as SwiftUI runs it, in
/// an `NSHostingView` inside a window that is never shown: attaching the view is its appearance,
/// replacing the window's content its disappearance, and the Agents tab's visibility is reported
/// through the reader view its watch installs. The whole views are not hosted: the island's keep
/// awake card asks the keep-awake daemon, and the Agents tab loads the real session history.
final class AgentResourceWatchTests: XCTestCase {
    private typealias F = AgentProcessFixture

    /// A monitor over a fake machine with one live session on a tab, its first loop asleep at
    /// the 30 s cadence.
    @MainActor
    private func monitorSampling(_ sleeps: LoopSleeps) async -> AgentResourceMonitor {
        let monitor = AgentResourceMonitor(
            sampler: FakeMachine().sampler(), now: { F.t0 }, sleep: { await sleeps.sleep($0) }
        )
        let slept = expectation(description: "the first loop sleeps")
        sleeps.expect(slept, atSleep: 1)
        monitor.update(sessions: [Fixture.agentSession(
            sessionID: "a", lastEventAt: F.t0, host: AgentHostInfo(pid: nil, bundleID: nil, tty: F.tab)
        )])
        await fulfillment(of: [slept], timeout: 5)
        return monitor
    }

    /// `content` in an `NSHostingView`, in a window that is never shown.
    @MainActor
    private func host(_ content: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// The visibility reader under `view`, as AppKit holds it.
    @MainActor
    private static func reader(under view: NSView) -> WindowVisibilityReader.ObserverView? {
        if let reader = view as? WindowVisibilityReader.ObserverView { return reader }
        for child in view.subviews {
            if let reader = reader(under: child) { return reader }
        }
        return nil
    }

    /// Runs `step` and waits for the loop restart it causes: the monitor's `count`-th sleep.
    @MainActor
    private func restart(
        _ sleeps: LoopSleeps, atSleep count: Int, _ what: String, _ step: () -> Void
    ) async {
        let restarted = expectation(description: what)
        sleeps.expect(restarted, atSleep: count)
        step()
        await fulfillment(of: [restarted], timeout: 5)
    }

    // MARK: The island

    @MainActor
    func testOpeningTheIslandHoldsTheFastCadenceAndClosingItReleasesIt() async {
        let sleeps = LoopSleeps()
        let monitor = await monitorSampling(sleeps)
        defer { monitor.update(sessions: []) }
        var window: NSWindow?
        defer { window?.close() }

        await restart(sleeps, atSleep: 2, "the island appeared") {
            window = host(Color.clear.modifier(PopoverView.ResourceWatch(monitor: monitor)))
        }
        XCTAssertEqual(monitor.cadence, 5, "the island is open")

        await restart(sleeps, atSleep: 3, "the island disappeared") {
            window?.contentView = NSView()
        }
        XCTAssertEqual(monitor.cadence, 30, "the island closed")
        XCTAssertEqual(sleeps.intervals, [30, 5, 30])
    }

    // MARK: The Agents tab

    @MainActor
    func testTheAgentsTabHoldsTheFastCadenceOnlyWhileItsWindowIsVisible() async throws {
        let sleeps = LoopSleeps()
        let monitor = await monitorSampling(sleeps)
        defer { monitor.update(sessions: []) }
        let window = host(Color.clear.modifier(AgentsHistoryView.ResourceWatch(monitor: monitor)))
        defer { window.close() }
        let reader = try XCTUnwrap(
            window.contentView.flatMap(Self.reader(under:)), "the tab reads its window's visibility"
        )
        XCTAssertEqual(monitor.cadence, 30, "a window never shown is not visible")

        await restart(sleeps, atSleep: 2, "the window showed") { reader.onChange?(true) }
        XCTAssertEqual(monitor.cadence, 5, "the window is visible")
        await restart(sleeps, atSleep: 3, "the window was hidden") { reader.onChange?(false) }
        XCTAssertEqual(monitor.cadence, 30, "closed, covered, minimised or on another Space")
        await restart(sleeps, atSleep: 4, "the window showed again") { reader.onChange?(true) }
        XCTAssertEqual(monitor.cadence, 5)
        await restart(sleeps, atSleep: 5, "the tab left the window") { window.contentView = NSView() }
        XCTAssertEqual(monitor.cadence, 30, "the tab is gone")
        XCTAssertEqual(sleeps.intervals, [30, 5, 30, 5, 30])
    }

    /// Leaving the tab removes the view, and the view's own disappearance lets go of the cadence:
    /// with the reader silenced first, removing the view still brings the 30 s cadence back.
    @MainActor
    func testLeavingTheAgentsTabReleasesItsHoldWithoutTheReadersWord() async throws {
        let sleeps = LoopSleeps()
        let monitor = await monitorSampling(sleeps)
        defer { monitor.update(sessions: []) }
        let window = host(Color.clear.modifier(AgentsHistoryView.ResourceWatch(monitor: monitor)))
        defer { window.close() }
        let reader = try XCTUnwrap(window.contentView.flatMap(Self.reader(under:)))

        await restart(sleeps, atSleep: 2, "the window showed") { reader.onChange?(true) }
        XCTAssertEqual(monitor.cadence, 5)
        reader.onChange = nil
        await restart(sleeps, atSleep: 3, "the tab left the window") { window.contentView = NSView() }
        XCTAssertEqual(monitor.cadence, 30, "the tab is gone")
    }
}
