import CoreGraphics

/// How tall the island's content may be, and how far the agents list gives way for it
/// (notch-island spec 2026-10-29 § 3.3, Height; § 3.9 `IslandHeightRules`; review findings
/// 7 and 11). It replaces the 3.x popover's constant chrome for the island:
/// - the budget is the placement rect — the island's window, from the screen's top to 8 pt
///   above the Dock — less the strip beside the camera and the island's bottom padding;
///   never "visible height − notch", which counts the menu bar twice. The panel keeps the
///   3.x rule, the visible height less `PopoverHeightRules.chrome` (plan ruling R7);
/// - the grid's lower row is as tall as its taller half, `max(agents, cost + keep awake)`,
///   so the agents list yields only while its half is the taller one;
/// - when even the list's first two rows cannot fit, the right column scrolls.
/// Pure: `IslandLayoutModel` measures and calls it.
enum IslandHeightRules {
    /// Between the strip beside the camera and the grid, on the island.
    static let islandTopInset: CGFloat = 12
    /// The panel's top row ("Omelette", updated-ago, the spinner): no camera to sit beside.
    static let panelHeaderHeight: CGFloat = 32

    /// What the right column measured, in points; nil until reported, and nil again once
    /// the part has left.
    struct Samples: Equatable, Sendable {
        /// Everything right of the habitat, at its own height.
        var rightColumn: CGFloat?
        /// The lower row's agents half at its own height, before the row stretches it.
        var agentsColumn: CGFloat?
        /// The cost tile over keep awake in the lower row.
        var costTile: CGFloat?
        /// The keep-awake card at its own height (`KeepAwakeCardLayout.naturalHeight`).
        var keepAwake: CGFloat?
        /// The agents list's report; nil while it has no rows.
        var list: AgentsListGeometry?
    }

    struct Outcome: Equatable, Sendable {
        /// The agents list's cap.
        let agentsListCap: CGFloat
        /// The right column does not fit even with the list at its floor: it scrolls.
        let scrolls: Bool
        /// The right column once the list takes `agentsListCap`; nil before it is measured.
        let rightColumn: CGFloat?
    }

    /// The most the content under the strip may measure on `screen`.
    static func budget(on screen: IslandScreen, screenVisibleHeight: CGFloat) -> CGFloat {
        guard let notch = screen.islandNotch else {
            return PopoverHeightRules.budget(screenVisibleHeight: screenVisibleHeight)
        }
        let window = IslandDisplayResolver.placement(
            on: screen, entry: .notch(displayID: screen.id), statusItemFrame: nil, panelWidth: 0, menuBarHeight: 0
        ).windowFrame
        return window.height - notch.height - IslandGeometry.islandBottomPadding
    }

    /// What the content holds outside the right column: on the island the inset under the
    /// strip; on the panel its padding, its top row and the gap under it.
    static func outsideRightColumn(_ kind: IslandDisplayResolver.Kind) -> CGFloat {
        switch kind {
        case .island: islandTopInset
        case .panel: 2 * ProviderGridRules.padding + panelHeaderHeight + ProviderGridRules.gap
        }
    }

    /// The right column's budget on `screen`.
    static func rightColumnBudget(on screen: IslandScreen, screenVisibleHeight: CGFloat) -> CGFloat {
        budget(on: screen, screenVisibleHeight: screenVisibleHeight)
            - outsideRightColumn(screen.islandNotch != nil ? .island : .panel)
    }

    /// The lower row's other half at its own height: the cost tile and the gap when it is
    /// there, then keep awake.
    static func otherColumn(costTile: CGFloat?, keepAwake: CGFloat?) -> CGFloat {
        (costTile.map { $0 + ProviderGridRules.gap } ?? 0) + (keepAwake ?? 0)
    }

    /// A page move's heights as drawn in one layout pass (P3b, § 3.2 Drill-down): the stage and
    /// the lower row between two pages' heights, and the destination's stage at rest.
    struct MoveHeights: Equatable, Sendable {
        var stageDrawn: CGFloat
        var stageAtRest: CGFloat
        var lowerRowDrawn: CGFloat
    }

    /// The right column as it will lay out at rest on a move's destination, from the column as
    /// drawn in the same pass: less the stage and the lower row as drawn, plus the destination's
    /// stage at rest and the lower row as it lays out (its taller half). Everything the move draws
    /// in between is left out, so what `outcome` calls `fixed` — the column but its lower row —
    /// no longer depends on the agents list, and the list's cap cannot chase its own height
    /// (P3b plan ruling R2).
    static func restingColumn(drawn: CGFloat, move: MoveHeights, samples: Samples) -> CGFloat {
        drawn - move.stageDrawn - move.lowerRowDrawn + move.stageAtRest
            + max(samples.agentsColumn ?? 0, otherColumn(costTile: samples.costTile, keepAwake: samples.keepAwake))
    }

    /// The agents list's cap and whether the right column scrolls. Without a budget or a
    /// measured column the list keeps today's 260; without a list there is nothing to cap.
    static func outcome(rightBudget: CGFloat?, samples: Samples) -> Outcome {
        guard let rightBudget, let right = samples.rightColumn else {
            return Outcome(agentsListCap: AgentsSection.defaultMaxListHeight, scrolls: false, rightColumn: nil)
        }
        let other = otherColumn(costTile: samples.costTile, keepAwake: samples.keepAwake)
        guard let list = samples.list, let agents = samples.agentsColumn else {
            return Outcome(agentsListCap: AgentsSection.defaultMaxListHeight, scrolls: right > rightBudget, rightColumn: right)
        }
        // Everything but the lower row, and the agents half without its list: neither moves
        // when the cap does, so the cap is a fixed point of the layout it causes.
        let fixed = right - max(agents, other)
        let chrome = agents - list.shownHeight
        let cap = PopoverHeightRules.agentsListHeight(
            budget: rightBudget,
            fixedHeight: fixed + chrome,
            // A list shorter than the other half saves nothing: the row stays that tall.
            minimumHeight: max(list.minimumHeight, other - chrome)
        )
        let shown = min(list.contentHeight ?? list.shownHeight, cap)
        let predicted = fixed + max(chrome + shown, other)
        return Outcome(agentsListCap: cap, scrolls: predicted > rightBudget, rightColumn: predicted)
    }
}
