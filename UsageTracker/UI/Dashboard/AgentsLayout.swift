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
}
