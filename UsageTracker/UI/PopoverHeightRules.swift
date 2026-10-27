import Foundation

/// How tall the popover's agents list may be on the screen the popover opens on (popover
/// height budget spec 2026-10-27). The list gives way so the limit tiles, the cost tile,
/// keep awake and the footer stay on screen: two rows on a small display, five on a large
/// one, the rest scrolling inside the list. Pure; `PopoverView` measures and calls it.
enum PopoverHeightRules {
    /// What the popover needs on screen beyond its content: NSPopover's arrow and frame,
    /// and a margin above the Dock.
    static let chrome: CGFloat = 40

    /// The floor of two rows that have not measured themselves: 54 + 1 + 54.
    static let unmeasuredMinimumHeight: CGFloat = 2 * AgentsSection.estimatedRowHeight + AgentsSection.hairlineHeight

    /// The most the popover's content may measure on a screen whose visible frame (menu
    /// bar and Dock left out) is this tall.
    static func budget(screenVisibleHeight: CGFloat) -> CGFloat {
        screenVisibleHeight - chrome
    }

    /// The list's cap: what the budget leaves after everything else in the popover
    /// (`fixedHeight`), rounded down to a whole point; never under the list's first two
    /// rows (`minimumHeight`, rounded up so the second row is never clipped); never over
    /// `AgentsSection.defaultMaxListHeight`, which wins when the two cross. Whole points,
    /// because a fractional cap would chase the fraction pixel rounding puts on the
    /// popover's height.
    static func agentsListHeight(budget: CGFloat, fixedHeight: CGFloat, minimumHeight: CGFloat) -> CGFloat {
        let left = (budget - fixedHeight).rounded(.down)
        return min(max(left, minimumHeight.rounded(.up)), AgentsSection.defaultMaxListHeight)
    }

    /// What the popover measured while one tab showed: its own height and that tab's
    /// list report (nil when the tab has no list, or it emptied).
    struct Samples: Equatable, Sendable {
        var popoverHeight: CGFloat?
        var list: AgentsListGeometry?
    }

    /// What a tab kept from its last open, in whole points: its fixed height and its
    /// list's floor.
    struct Persisted: Equatable, Sendable {
        let fixedHeight: CGFloat
        let minimumHeight: CGFloat
    }

    /// A tab's fixed height, everything in the popover but the list: the popover less the
    /// list as shown, both sampled on that tab. A tab that has not sampled the popover
    /// yet takes the value kept for it; nil when there is none either.
    static func fixedHeight(_ samples: Samples?, persisted: CGFloat?) -> CGFloat? {
        guard let popover = samples?.popoverHeight else { return persisted }
        return popover - (samples?.list?.shownHeight ?? 0)
    }

    /// The current tab's cap. Its fixed height does not move when the cap does, because a
    /// new cap changes the tab's popover and list samples by the same amount: the cap is
    /// a fixed point, not a loop. The floor is the list's report, else the kept one, else
    /// two unmeasured rows. No screen known, or nothing sampled and nothing kept (a fresh
    /// install): today's fixed cap.
    static func agentsListCap(screenVisibleHeight: CGFloat?, samples: Samples?, persisted: Persisted?) -> CGFloat {
        guard let screenVisibleHeight,
              let fixed = Self.fixedHeight(samples, persisted: persisted?.fixedHeight)
        else { return AgentsSection.defaultMaxListHeight }
        return agentsListHeight(
            budget: Self.budget(screenVisibleHeight: screenVisibleHeight),
            fixedHeight: fixed,
            minimumHeight: samples?.list?.minimumHeight ?? persisted?.minimumHeight ?? unmeasuredMinimumHeight
        )
    }

    // MARK: - Kept across launches

    /// The `UserDefaults` key each tab's last fixed height and floor are kept under, so
    /// the first open after a launch starts from them: one string for every tab,
    /// "all=812/161,claude=905/109". A view-level preference, forgotten by Reset all
    /// settings.
    static let fixedHeightsKey = "popoverFixedHeights"

    /// What `tab` kept; nil when there is nothing or its entry does not read.
    static func persisted(for tab: String, in stored: String) -> Persisted? {
        storedPairs(stored)[tab]
    }

    /// `stored` with `tab` at `persisted` in whole points rounded up, every other tab
    /// kept, in id order. A negative, non-finite or absurd height (100 000 pt or more) is
    /// not stored; an entry that no longer reads is dropped.
    static func storing(_ persisted: Persisted, for tab: String, in stored: String) -> String {
        let heights = [persisted.fixedHeight, persisted.minimumHeight]
        guard heights.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 100_000 }) else { return stored }
        var pairs = storedPairs(stored)
        pairs[tab] = Persisted(
            fixedHeight: persisted.fixedHeight.rounded(.up),
            minimumHeight: persisted.minimumHeight.rounded(.up)
        )
        return pairs
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Int($0.value.fixedHeight))/\(Int($0.value.minimumHeight))" }
            .joined(separator: ",")
    }

    /// Every readable "tab=fixed/minimum" entry in `stored`: exactly two whole,
    /// non-negative numbers.
    private static func storedPairs(_ stored: String) -> [String: Persisted] {
        var pairs: [String: Persisted] = [:]
        for entry in stored.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let numbers = parts[1].split(separator: "/", omittingEmptySubsequences: false)
            guard numbers.count == 2,
                  let fixed = Int(numbers[0]), fixed >= 0,
                  let minimum = Int(numbers[1]), minimum >= 0
            else { continue }
            pairs[String(parts[0])] = Persisted(fixedHeight: CGFloat(fixed), minimumHeight: CGFloat(minimum))
        }
        return pairs
    }
}
