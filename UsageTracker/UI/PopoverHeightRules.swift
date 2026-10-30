import Foundation

/// The 3.x popover's height budget (popover height budget spec 2026-10-27) as 4.0 keeps
/// it: the panel's budget, the visible height less `chrome` (notch-island spec 2026-10-29
/// § 3.3: "the panel keeps today's rule"), and the agents list's clamp that
/// `IslandHeightRules` sizes the list with. Pure.
enum PopoverHeightRules {
    /// What the panel needs on screen beyond its content: the gap under the status item,
    /// its shadow, and a margin above the Dock.
    static let chrome: CGFloat = 40

    /// The floor of two rows that have not measured themselves: 54 + 1 + 54.
    static let unmeasuredMinimumHeight: CGFloat = 2 * AgentsSection.estimatedRowHeight + AgentsSection.hairlineHeight

    /// The most the panel's content may measure on a screen whose visible frame (menu
    /// bar and Dock left out) is this tall.
    static func budget(screenVisibleHeight: CGFloat) -> CGFloat {
        screenVisibleHeight - chrome
    }

    /// The visible height `budget` takes (reviewer V4). With the menu bar set to hide, the
    /// visible frame reaches the screen's top (nothing reserved there), but the panel still
    /// opens below the menu bar, so the menu bar's height comes off; otherwise the visible
    /// frame already leaves it out.
    static func screenVisibleHeight(frameMaxY: CGFloat, visibleFrameMaxY: CGFloat, visibleFrameHeight: CGFloat, menuBarHeight: CGFloat) -> CGFloat {
        visibleFrameMaxY >= frameMaxY ? visibleFrameHeight - menuBarHeight : visibleFrameHeight
    }

    /// The list's cap: what the budget leaves after everything else (`fixedHeight`),
    /// rounded down to a whole point; never under the list's first two rows
    /// (`minimumHeight`, rounded up so the second row is never clipped); never over
    /// `AgentsSection.defaultMaxListHeight`, which wins when the two cross. Whole points,
    /// because a fractional cap would chase the fraction pixel rounding puts on the
    /// content's height.
    ///
    /// Always a finite number of points: when the budget or the fixed height is not a
    /// number, nothing is left to compute and the list keeps
    /// `AgentsSection.defaultMaxListHeight`; a floor that is not a number, or below every
    /// height, counts as two unmeasured rows. Infinities give the clamp's ends.
    static func agentsListHeight(budget: CGFloat, fixedHeight: CGFloat, minimumHeight: CGFloat) -> CGFloat {
        let left = (budget - fixedHeight).rounded(.down)
        guard !left.isNaN else { return AgentsSection.defaultMaxListHeight }
        let floor = minimumHeight.isNaN || minimumHeight == -.infinity
            ? unmeasuredMinimumHeight
            : minimumHeight.rounded(.up)
        return min(max(left, floor), AgentsSection.defaultMaxListHeight)
    }

    /// The key 3.x kept each tab's fixed height and list floor under ("all=812/161,…").
    /// Nothing writes it since 4.0 measures each open; Reset all settings still removes
    /// what an earlier version left.
    static let fixedHeightsKey = "popoverFixedHeights"
}
