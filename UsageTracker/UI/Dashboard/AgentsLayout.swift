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
}
