import Combine
import XCTest
@testable import Omelette

/// Popover height budget spec 2026-10-27, § Design (Q1) and the owner's check on the
/// 14-inch: the agents list's caps live in a model that re-renders the popover only when a
/// cap changes, holds the samples back while a tab switch cross-fades, and hands the kept
/// heights to `UserDefaults` only when asked (the popover's close), and only when they
/// changed.
@MainActor
final class PopoverHeightModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func list(_ shown: CGFloat, _ minimum: CGFloat = 109) -> AgentsListGeometry {
        AgentsListGeometry(shownHeight: shown, minimumHeight: minimum)
    }

    /// The 14-inch (visible 945, budget 905) with All sampled: 905 − (500 − 100) = 505,
    /// five rows.
    private func fourteenInchAtFiveRows(now: @escaping () -> Date) -> PopoverHeightModel {
        let model = PopoverHeightModel(stored: "", now: now)
        model.setScreen(visibleHeight: 945)
        model.recordAgentsList(list(100), tab: "all")
        model.recordPopoverHeight(500, tab: "all")
        return model
    }

    func testASampleThatLeavesTheCapAsItWasPublishesNothing() {
        let model = fourteenInchAtFiveRows(now: { self.t0 })
        XCTAssertEqual(model.cap(for: "all"), 260)
        var published: [[String: CGFloat]] = []
        let subscription = model.$caps.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        // 905 − (520 − 100) = 485: still five rows.
        model.recordPopoverHeight(520, tab: "all")
        // A new floor under the clamp's top, then the same report again.
        model.recordAgentsList(list(100, 161), tab: "all")
        model.recordAgentsList(list(100, 161), tab: "all")

        XCTAssertEqual(published.count, 0, "an equal cap re-rendered the popover")
        XCTAssertEqual(model.cap(for: "all"), 260)
    }

    func testASampleThatMovesTheCapPublishesItOnce() {
        let model = fourteenInchAtFiveRows(now: { self.t0 })
        var published: [[String: CGFloat]] = []
        let subscription = model.$caps.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        // Keep awake's notice appears: 905 − (800 − 100) = 205.
        model.recordPopoverHeight(800, tab: "all")

        XCTAssertEqual(published, [["all": 205]])
        XCTAssertEqual(model.cap(for: "all"), 205)
    }

    func testDuringATabSwitchSamplesWaitAndTheFlushPublishesOnce() {
        var clock = t0
        let model = fourteenInchAtFiveRows(now: { clock })
        var published: [[String: CGFloat]] = []
        let subscription = model.$caps.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }
        // The tab cross-fade (0.18 s) and 0.1 s for its last layout.
        XCTAssertEqual(PopoverHeightModel.transitionWindow, 0.28, accuracy: 0.000_1)

        model.tabChanged(to: "claude")
        // Both pages overlap while they fade; the popover is the taller one.
        clock = t0.addingTimeInterval(0.1)
        model.recordPopoverHeight(900, tab: "claude")
        model.recordAgentsList(list(120, 121), tab: "claude")
        model.recordPopoverHeight(880, tab: "claude")
        model.recordPopoverHeight(800, tab: "all")
        XCTAssertEqual(published.count, 0, "the popover re-rendered during the cross-fade")

        model.flush()
        // Claude: 905 − (880 − 120) = 145. All: 905 − (800 − 100) = 205.
        XCTAssertEqual(published, [["all": 205, "claude": 145]])

        // After the flush a sample publishes at once: 905 − (860 − 120) = 165.
        model.recordPopoverHeight(860, tab: "claude")
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.last?["claude"], 165)

        // A window that has run out holds nothing back, flushed or not:
        // 905 − (900 − 100) = 105, two rows.
        model.tabChanged(to: "all")
        clock = t0.addingTimeInterval(0.1 + 0.29)
        model.recordPopoverHeight(900, tab: "all")
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published.last?["all"], 109)
    }

    /// Plan ruling R1: a switch that leaves the popover as tall as it was fires no geometry
    /// action, so the new tab starts from the last popover height, even over a sample of
    /// its own, which can be stale; when the new tab's layout differs, its geometry action
    /// overwrites the seed.
    func testATabSwitchSeedsTheNewTabFromTheLastPopoverHeight() {
        let model = PopoverHeightModel(stored: "", now: { self.t0 })
        model.setScreen(visibleHeight: 945)
        model.recordAgentsList(list(100), tab: "all")
        model.recordPopoverHeight(800, tab: "all")
        XCTAssertEqual(model.cap(for: "all"), 205)
        // A tab never seen and not kept: today's cap.
        XCTAssertEqual(model.cap(for: "claude"), 260)

        model.tabChanged(to: "claude")
        model.flush()
        // Claude's own sample is the 800 it was seeded with: 905 − 800 = 105, two rows.
        XCTAssertEqual(model.cap(for: "claude"), 109)

        // A keep-awake notice comes up on Claude: the popover is 1 000 tall. All's own 800
        // was taken before it and is stale; the switch back leaves the height as it was, so
        // All starts from the 1 000 laid out last: 905 − (1 000 − 100) = 5, two rows.
        model.recordPopoverHeight(1_000, tab: "claude")
        model.tabChanged(to: "all")
        model.flush()
        XCTAssertEqual(model.cap(for: "all"), 109)
        // All's own layout turns out shorter: its geometry action overwrites the seed.
        model.recordPopoverHeight(800, tab: "all")
        XCTAssertEqual(model.cap(for: "all"), 205)
    }

    /// Plan rulings C3 and R3, written once per close instead of on every layout pass.
    func testTheKeptHeightsAreWrittenOnlyWhenTheyChanged() {
        let model = PopoverHeightModel(stored: "claude=905/109", now: { self.t0 })
        var writes: [String] = []
        model.persistNow { writes.append($0) }
        XCTAssertEqual(writes, [], "nothing changed since the launch read it")

        model.setScreen(visibleHeight: 945)
        model.recordAgentsList(list(100, 121), tab: "all")
        model.recordPopoverHeight(900, tab: "all")
        XCTAssertEqual(model.persistedString(), "all=800/121,claude=905/109")
        XCTAssertEqual(writes, [], "a sample wrote before the popover closed")

        model.persistNow { writes.append($0) }
        model.persistNow { writes.append($0) }
        XCTAssertEqual(writes, ["all=800/121,claude=905/109"])

        // A new pair goes out at the next close.
        model.recordPopoverHeight(910, tab: "all")
        model.persistNow { writes.append($0) }
        XCTAssertEqual(writes, ["all=800/121,claude=905/109", "all=810/121,claude=905/109"])
    }

    /// The next open on another screen: every known tab's cap follows it, the sampled ones
    /// and the ones only kept from an earlier launch, in one publish.
    func testANewScreenRecomputesTheCaps() {
        let model = PopoverHeightModel(stored: "claude=760/109", now: { self.t0 })
        model.recordAgentsList(list(100), tab: "all")
        model.recordPopoverHeight(900, tab: "all")
        // No screen yet: today's cap.
        XCTAssertEqual(model.cap(for: "all"), 260)
        var published: [[String: CGFloat]] = []
        let subscription = model.$caps.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        // The 14-inch: All 905 − 800 = 105 → two rows; Claude 905 − 760 = 145.
        model.setScreen(visibleHeight: 945)
        XCTAssertEqual(published, [["all": 109, "claude": 145]])
        model.setScreen(visibleHeight: 945)
        XCTAssertEqual(published.count, 1, "the same screen re-rendered the popover")

        // An external display: five rows on both.
        model.setScreen(visibleHeight: 1_400)
        XCTAssertEqual(published.last, ["all": 260, "claude": 260])
        XCTAssertEqual(published.count, 2)
    }
}
