import Combine
import Foundation

/// The popover's agents-list caps, one per tab (popover height budget spec 2026-10-27),
/// kept out of `PopoverView`'s state so a geometry sample re-renders the popover only
/// when it moves a cap. While a tab switch cross-fades, samples are kept but the caps
/// wait for `flush()`; the kept heights reach `UserDefaults` only through `persistNow`,
/// when the popover closes. `StatusBarController` owns one for the popover's life. The
/// arithmetic is `PopoverHeightRules`'.
@MainActor
final class PopoverHeightModel: ObservableObject {
    /// How long a tab switch holds the caps back: the tab cross-fade (`OMTransitionRules`)
    /// and 0.1 s for the layout after it to land.
    nonisolated static let transitionWindow: TimeInterval =
        (OMTransitionRules.tab(reduceMotion: false)?.duration ?? 0) + 0.1

    /// Each tab's cap as last computed. Assigned only when a value changed, so a sample
    /// that leaves every cap where it was never re-renders the popover.
    @Published private(set) var caps: [String: CGFloat] = [:]

    /// The visible height of the screen the popover opens on; nil before the first show.
    private(set) var screenVisibleHeight: CGFloat?
    /// What the popover measured on each tab: its own height and the tab's list report,
    /// both taken while that tab showed (plan ruling C1). An entry outlives the tab.
    private(set) var tabSamples: [String: PopoverHeightRules.Samples] = [:]
    /// The popover's height as last laid out, to seed a tab with no sample of its own when
    /// a switch leaves the height as it was (plan ruling R1).
    private(set) var lastPopoverHeight: CGFloat?
    /// Each tab's fixed height and list floor (plan rulings C3, R3): read at launch,
    /// updated here as tabs sample, written by `persistNow`. Reset all settings removes the
    /// key but not this copy, which stays stale until the next launch; a close after a
    /// new sample writes it back. Accepted: the heights only size the list's first frame.
    private(set) var stored: String
    /// Until when a tab switch holds the caps back; nil outside a switch.
    private(set) var transitionUntil: Date?

    /// The string as last written (or read at launch), so an unchanged one is not
    /// written again.
    private var lastWritten: String
    private let now: () -> Date

    init(stored: String, now: @escaping () -> Date = Date.init) {
        self.stored = stored
        self.lastWritten = stored
        self.now = now
    }

    /// The screen the popover is about to open on, set before each show. A new one moves
    /// every known tab's cap, sampled or only kept.
    func setScreen(visibleHeight: CGFloat?) {
        guard visibleHeight != screenVisibleHeight else { return }
        screenVisibleHeight = visibleHeight
        publish(knownTabs)
    }

    /// The popover's own height, laid out for `tab`.
    func recordPopoverHeight(_ height: CGFloat, tab: String) {
        lastPopoverHeight = height
        file(popoverHeight: height, tab: tab)
    }

    /// `tab`'s list report; nil (the list emptied) drops it.
    func recordAgentsList(_ geometry: AgentsListGeometry?, tab: String) {
        var samples = tabSamples[tab] ?? PopoverHeightRules.Samples()
        guard samples.list != geometry else { return }
        samples.list = geometry
        tabSamples[tab] = samples
        sampled(tab)
    }

    /// A tab switch: the caps wait out the cross-fade (`transitionWindow`, then `flush()`),
    /// during which both pages overlap and the popover is the taller one. A tab with no
    /// popover sample of its own starts from the last height, because a switch that
    /// leaves the height as it was fires no geometry action (plan ruling R1).
    func tabChanged(to tab: String) {
        transitionUntil = now().addingTimeInterval(Self.transitionWindow)
        if tabSamples[tab]?.popoverHeight == nil, let height = lastPopoverHeight {
            file(popoverHeight: height, tab: tab)
        }
    }

    /// The switch is over: every tab's cap from its samples, in one publish of what
    /// changed.
    func flush() {
        transitionUntil = nil
        publish(knownTabs)
    }

    /// `tab`'s cap: as last computed, else what it kept from an earlier launch, else
    /// today's 260 pt.
    func cap(for tab: String) -> CGFloat {
        caps[tab] ?? PopoverHeightRules.agentsListCap(
            screenVisibleHeight: screenVisibleHeight,
            samples: nil,
            persisted: PopoverHeightRules.persisted(for: tab, in: stored)
        )
    }

    /// Every tab's fixed height and list floor, as `PopoverHeightRules.fixedHeightsKey`
    /// keeps them.
    func persistedString() -> String {
        stored
    }

    /// Hands the kept heights to `store` when they changed since the last write.
    func persistNow(into store: (String) -> Void) {
        guard stored != lastWritten else { return }
        store(stored)
        lastWritten = stored
    }

    // MARK: - Private

    private func file(popoverHeight height: CGFloat, tab: String) {
        var samples = tabSamples[tab] ?? PopoverHeightRules.Samples()
        guard samples.popoverHeight != height else { return }
        samples.popoverHeight = height
        tabSamples[tab] = samples
        sampled(tab)
    }

    /// `tab`'s samples changed: keep its pair, and outside a tab switch recompute its cap.
    private func sampled(_ tab: String) {
        keep(tab)
        if let transitionUntil, now() < transitionUntil { return }
        publish([tab])
    }

    /// The tab's fixed height and list floor, once it has both samples.
    private func keep(_ tab: String) {
        guard let samples = tabSamples[tab],
              let fixed = PopoverHeightRules.fixedHeight(samples, persisted: nil),
              let list = samples.list
        else { return }
        stored = PopoverHeightRules.storing(
            PopoverHeightRules.Persisted(fixedHeight: fixed, minimumHeight: list.minimumHeight),
            for: tab,
            in: stored
        )
    }

    /// Every tab whose cap can differ from today's 260 pt: sampled, kept, or computed.
    private var knownTabs: Set<String> {
        Set(tabSamples.keys)
            .union(PopoverHeightRules.persistedTabs(in: stored))
            .union(caps.keys)
    }

    /// Recomputes `tabs`' caps and assigns `caps` once, only when one of them changed.
    private func publish(_ tabs: some Sequence<String>) {
        var next = caps
        for tab in tabs {
            next[tab] = PopoverHeightRules.agentsListCap(
                screenVisibleHeight: screenVisibleHeight,
                samples: tabSamples[tab],
                persisted: PopoverHeightRules.persisted(for: tab, in: stored)
            )
        }
        if next != caps { caps = next }
    }
}
