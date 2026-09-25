import SwiftUI

/// The Agents tab's measurements, from `Dashboard-Agents(-Light).dc.html`. The column's
/// side gutters are `DashboardShellLayout.columnLeading` / `columnTrailing`, shared with
/// the header.
enum AgentsLayout {
    // MARK: Title row

    /// Between the source filter and the range picker (`gap: 12px`).
    static let headerControlsSpacing: CGFloat = 12

    // MARK: Column (`padding: 24px 32px 32px 30px; gap: 20px`)

    /// Between the cards.
    static let cardSpacing: CGFloat = 20
    /// Above the first card. The mockup's gap is 20 pt; `DashboardHeader` already pads
    /// 12 pt below itself (`DashboardWindow.swift`, `.padding(.bottom, 12)`).
    static let headerGap: CGFloat = 8
    /// Below the last card.
    static let columnBottom: CGFloat = 32

    // MARK: Cards (`padding: 20px 24px`)

    static let cardVerticalPadding: CGFloat = 20
    static let cardHorizontalPadding: CGFloat = 24

    // MARK: Stats row (`grid-template-columns: repeat(3, 1fr); gap: 24px`)

    /// Between columns; also the padding after a column's hairline.
    static let statColumnGap: CGFloat = 24
    /// The label: 12.5 pt semibold, secondary.
    static let statLabelSize: CGFloat = 12.5
    /// The figure: 26 pt bold SF Pro Rounded, tabular, tracked −0.5.
    static let statValueSize: CGFloat = 26
    static let statValueTracking: CGFloat = -0.5
    static let statLabelValueSpacing: CGFloat = 3

    // MARK: Live card (`padding: 20px 24px 8px`)

    /// "Live": 15 pt, weight 650 (semibold).
    static let liveTitleSize: CGFloat = 15
    /// "3 sessions" and the empty row: 12.5 pt, secondary.
    static let liveCountSize: CGFloat = 12.5
    static let liveTitleCountSpacing: CGFloat = 10
    /// The mockup's 6 pt spacer between the header and the first row.
    static let liveHeaderGap: CGFloat = 6
    static let liveBottomPadding: CGFloat = 8
    /// A row's padding above and below (`padding: 14px 0`).
    static let liveRowPadding: CGFloat = 14
    /// The rows' container inset, so a row's own 14 pt lands its logo on the title's
    /// 24 pt edge.
    static var liveRowsInset: CGFloat { cardHorizontalPadding - OMAgentRow.horizontalPadding }
    /// Added above and below each `OMAgentRow`, whose own padding is 11 pt at either size.
    static var liveRowOuterPadding: CGFloat { liveRowPadding - OMAgentRow.verticalPadding }
}
