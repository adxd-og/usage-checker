import SwiftUI

/// The Overview's grid (`Dashboard-Overview(-Light).dc.html`): twelve columns, the rings
/// card over seven and the CLI card over five, 20 pt apart, Tokens today under both. Which
/// cards a provider gets is decided here too: no cost log, no CLI or Tokens card.
enum OverviewLayout {
    static let spacing: CGFloat = 20
    static let ringsSpan: CGFloat = 7
    static let cliSpan: CGFloat = 5
    /// The narrowest row that still gives the rings card the 504 pt its ring and legend
    /// need (28 + 232 + 36 + 180 + 28) at seven twelfths of the row after the gap.
    static let minimumSideBySideWidth: CGFloat = 884
    /// Under the header's own 12 pt bottom padding: the mockup's 20 pt between the header
    /// row and the cards.
    static let contentTop: CGFloat = 8
    /// The detail column's bottom padding (`24px 32px 32px 30px`).
    static let contentBottom: CGFloat = 32

    /// The two cards' widths when they sit side by side.
    struct Columns: Equatable {
        let rings: CGFloat
        let cli: CGFloat
    }

    /// The width the row is laid out at: the proposal when it is a real width; the
    /// side-by-side minimum when SwiftUI asks for an ideal size (nil) or proposes an
    /// unbounded or undefined width, where `shared − rings` would be ∞ − ∞, NaN.
    static func resolvedWidth(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return minimumSideBySideWidth }
        return proposed
    }

    /// Seven twelfths and five of the row after the gap, or nil when the row is too narrow
    /// for the rings card and the cards stack at full width. A width that is not finite is
    /// first resolved to `resolvedWidth`'s fallback.
    static func columns(width: CGFloat) -> Columns? {
        let width = resolvedWidth(width)
        guard width >= minimumSideBySideWidth else { return nil }
        let shared = width - spacing
        let rings = (shared * ringsSpan / (ringsSpan + cliSpan)).rounded(.down)
        return Columns(rings: rings, cli: shared - rings)
    }

    /// Today's CLI dollars need a local cost log.
    static func showsCLICard(hasBreakdown: Bool) -> Bool {
        hasBreakdown
    }

    /// Tokens today needs the log and something from today: a bar of nothing says less
    /// than no card.
    static func showsTokensCard(hasBreakdown: Bool, todayTokens: Int) -> Bool {
        hasBreakdown && todayTokens > 0
    }
}

/// The Overview's top row on the mockup's grid: the two cards side by side at seven and
/// five twelfths, as tall as each other, when `OverviewLayout.columns` allows; stacked at
/// full width otherwise. One card (a provider with no cost log) takes the whole row.
struct OverviewColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = OverviewLayout.resolvedWidth(proposal.width)
        if subviews.count == 2, let columns = OverviewLayout.columns(width: width) {
            return CGSize(width: width, height: rowHeight(subviews, columns))
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = OverviewLayout.spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if subviews.count == 2, let columns = OverviewLayout.columns(width: bounds.width) {
            let height = rowHeight(subviews, columns)
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.rings, height: height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + columns.rings + OverviewLayout.spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.cli, height: height)
            )
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height + OverviewLayout.spacing
        }
    }

    /// The taller card's height: the shorter one stretches to it, as a grid row does.
    private func rowHeight(_ subviews: Subviews, _ columns: OverviewLayout.Columns) -> CGFloat {
        max(
            subviews[0].sizeThatFits(ProposedViewSize(width: columns.rings, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: columns.cli, height: nil)).height
        )
    }
}
