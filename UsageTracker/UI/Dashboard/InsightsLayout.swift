import CoreGraphics

/// How the session window card and the two figure cards share the first row.
enum InsightsTopRow: Equatable, Sendable {
    /// The mockup's 12-column grid: the session window spans 8 columns, the cards 4.
    case sideBySide(sessionWidth: CGFloat, cardsWidth: CGFloat)
    /// Too narrow for the grid: the session window full width, the cards under it.
    case stacked
}

/// The Insights tab's first row (`Dashboard-Insights.dc.html`: `grid-template-columns:
/// repeat(12, minmax(0, 1fr)); gap: 20px`, the session window `span 8`).
enum InsightsLayout {
    static let columns = 12
    static let sessionColumns = 8
    /// Below this content width the session window's project rows (170 + 90 + 80 pt of
    /// fixed columns and a bar) and a 30 pt figure no longer fit their columns. At it,
    /// the session window is 500 pt and the cards 240.
    static let minimumSideBySideWidth: CGFloat = 760

    static func topRow(contentWidth: CGFloat) -> InsightsTopRow {
        guard contentWidth >= minimumSideBySideWidth else { return .stacked }
        let gap = InsightsMetrics.gap
        let column = (contentWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let session = column * CGFloat(sessionColumns) + gap * CGFloat(sessionColumns - 1)
        return .sideBySide(sessionWidth: session, cardsWidth: contentWidth - gap - session)
    }
}
