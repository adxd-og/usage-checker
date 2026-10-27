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

    /// The hold lasts the tab cross-fade (0.18 s) and 0.1 s for the layout after it; under
    /// Reduce Motion the switch is instant, so only the 0.1 s.
    func testUnderReduceMotionATabSwitchHoldsTheCapsOnlyForItsLayout() {
        XCTAssertEqual(PopoverHeightModel.transitionWindow(reduceMotion: false), 0.28, accuracy: 0.000_1)
        XCTAssertEqual(PopoverHeightModel.transitionWindow(reduceMotion: true), 0.1, accuracy: 0.000_1)

        var clock = t0
        let model = fourteenInchAtFiveRows(now: { clock })
        model.tabChanged(to: "claude", reduceMotion: true)
        // 0.15 s later the instant switch's hold is over: 905 − (800 − 100) = 205 at once.
        clock = t0.addingTimeInterval(0.15)
        model.recordPopoverHeight(800, tab: "all")
        XCTAssertEqual(model.cap(for: "all"), 205)

        // With motion, 0.15 s is still inside the cross-fade: nothing moves until the flush.
        model.tabChanged(to: "claude", reduceMotion: false)
        clock = t0.addingTimeInterval(0.3)
        model.recordPopoverHeight(500, tab: "all")
        XCTAssertEqual(model.cap(for: "all"), 205)
        model.flush()
        XCTAssertEqual(model.cap(for: "all"), 260)
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
        // What `UserDefaults` holds under the key, and every write to it.
        var defaults: String? = "claude=905/109"
        var writes: [String] = []
        func close() {
            model.persistNow(current: defaults) { defaults = $0; writes.append($0) }
        }
        close()
        XCTAssertEqual(writes, [], "nothing changed since the launch read it")

        model.setScreen(visibleHeight: 945)
        model.recordAgentsList(list(100, 121), tab: "all")
        model.recordPopoverHeight(900, tab: "all")
        XCTAssertEqual(model.persistedString(), "all=800/121,claude=905/109")
        XCTAssertEqual(writes, [], "a sample wrote before the popover closed")

        close()
        close()
        XCTAssertEqual(writes, ["all=800/121,claude=905/109"])

        // A new pair goes out at the next close.
        model.recordPopoverHeight(910, tab: "all")
        close()
        XCTAssertEqual(writes, ["all=800/121,claude=905/109", "all=810/121,claude=905/109"])
    }

    /// Reset all settings after the launch removes the key, not the model's copy: the next
    /// close keeps only the tabs this session sampled, so Claude's height read at launch
    /// is really forgotten. With the key in place the pairs are merged as usual.
    func testAResetAfterLaunchKeepsOnlyWhatThisSessionSampled() {
        let reset = PopoverHeightModel(stored: "claude=905/109", now: { self.t0 })
        reset.setScreen(visibleHeight: 945)
        reset.recordAgentsList(list(100, 121), tab: "all")
        reset.recordPopoverHeight(900, tab: "all")
        var writes: [String] = []
        reset.persistNow(current: nil) { writes.append($0) }
        XCTAssertEqual(writes, ["all=800/121"])
        XCTAssertEqual(reset.persistedString(), "all=800/121")
        reset.persistNow(current: "all=800/121") { writes.append($0) }
        XCTAssertEqual(writes.count, 1, "the same pairs were written twice")

        // A session that sampled nothing leaves the removed key removed.
        let idle = PopoverHeightModel(stored: "claude=905/109", now: { self.t0 })
        idle.persistNow(current: nil) { writes.append($0) }
        XCTAssertEqual(writes.count, 1, "a reset key came back with the heights read at launch")

        let kept = PopoverHeightModel(stored: "claude=905/109", now: { self.t0 })
        kept.recordAgentsList(list(100, 121), tab: "all")
        kept.recordPopoverHeight(900, tab: "all")
        kept.persistNow(current: "claude=905/109") { writes.append($0) }
        XCTAssertEqual(writes.last, "all=800/121,claude=905/109")
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
