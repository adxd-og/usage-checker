import SwiftUI

/// History's measurements, from `Dashboard-History-*.dc.html` and
/// `Dashboard-Quota-History.dc.html` (liquid-glass spec § Screens, the History rows).
/// Numbers only, and the one width decision the chat list takes; the views read them.
enum HistoryLayout {}

// MARK: - Page

extension HistoryLayout {
    /// The mockups' 20 pt between the title and the controls row, less the 12 pt
    /// `DashboardHeader` leaves under itself.
    static let controlsTopPadding: CGFloat = 8
    /// Between the controls in the row (`gap: 10px`).
    static let controlSpacing: CGFloat = 10
}

// MARK: - Cards and the chat list

extension HistoryLayout {
    /// Between the controls row and the cards, and between cards (`gap: 20px`).
    static let sectionSpacing: CGFloat = 20
    /// A card's title ("Cost per day", "Sessions": 15 px, weight 650) and the caption
    /// beside it (12.5 px).
    static let cardTitleSize: CGFloat = 15
    static let cardCaptionSize: CGFloat = 12.5
    /// The Sessions card: `padding: 20px 24px 8px`; its header row `padding-bottom: 12px`.
    static var sessionsCardPadding: EdgeInsets { EdgeInsets(top: 20, leading: 24, bottom: 8, trailing: 24) }
    static let sessionsHeaderBottom: CGFloat = 12
    static let cardHorizontalPadding: CGFloat = 24
    /// Column titles 12 px semibold; a row `padding: 11px 0`; the name 13.5 px, the
    /// project 12 px, the cost 14.5 px bold.
    static let columnTitleSize: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 11
    static let rowTitleSize: CGFloat = 13.5
    static let rowSubtitleSize: CGFloat = 12
    static let rowCostSize: CGFloat = 14.5
    // The row's grid: `22px minmax(0, 1fr) 140px 80px 96px 104px`, `column-gap: 18px`.
    static let chevronWidth: CGFloat = 22
    static let columnGap: CGFloat = 18
    /// The least a chat's name keeps before the row folds: 2.7's figure (the mockup's
    /// `minmax(0, 1fr)` has no floor).
    static let titleMinWidth: CGFloat = 160
    static let lastActiveWidth: CGFloat = 140
    static let turnsWidth: CGFloat = 80
    static let tokensWidth: CGFloat = 96
    static let costWidth: CGFloat = 104

    /// The width the wide row needs: its six columns and five gaps.
    static var minimumWideListWidth: CGFloat {
        chevronWidth + titleMinWidth + lastActiveWidth + turnsWidth + tokensWidth + costWidth
            + 5 * columnGap
    }

    /// The list's width inside a detail column this wide: the column's gutters and the
    /// card's own padding come off.
    static func listWidth(detailWidth: CGFloat) -> CGFloat {
        detailWidth - DashboardShellLayout.columnLeading - DashboardShellLayout.columnTrailing
            - 2 * cardHorizontalPadding
    }

    /// Whether the chat list draws its five columns. The page measures it once, for the
    /// column header and every row alike.
    static func isWideList(detailWidth: CGFloat) -> Bool {
        listWidth(detailWidth: detailWidth) >= minimumWideListWidth
    }
}

// MARK: - An open chat

extension HistoryLayout {
    /// `margin: 0 0 12px 42px; padding: 20px 22px; border-radius: 18px; gap: 24px`.
    static let panelLeadingInset: CGFloat = 42
    static let panelBottomInset: CGFloat = 12
    static var panelPadding: EdgeInsets { EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22) }
    static let panelRadius: CGFloat = 18
    static let panelSectionSpacing: CGFloat = 24
    /// By model and By day side by side (`gap: 36px`); every table's `column-gap: 16px`.
    static let panelTablesGap: CGFloat = 36
    static let panelColumnGap: CGFloat = 16
    static let panelNameMinWidth: CGFloat = 120
    // By model, By day: `minmax(0, 1fr) 56px 64px 72px`.
    static let panelTurnsWidth: CGFloat = 56
    static let panelTokensWidth: CGFloat = 64
    static let panelCostWidth: CGFloat = 72
    // Sub-agents: `minmax(0, 1fr) 110px 70px 64px 80px 80px`.
    static let agentModelWidth: CGFloat = 110
    static let agentEffortWidth: CGFloat = 70
    static let agentTurnsWidth: CGFloat = 64
    static let agentTokensWidth: CGFloat = 80
    static let agentCostWidth: CGFloat = 80
    /// The money bar: 8 pt, 2 pt gaps, 3 pt least; a row's share bar: 4 pt.
    static let moneyBarHeight: CGFloat = 8
    static let moneyBarGap: CGFloat = 2
    static let moneyBarMinimum: CGFloat = 3
    static let shareBarHeight: CGFloat = 4
    static let panelRowVerticalPadding: CGFloat = 7
}

// MARK: - Chart card

extension HistoryLayout {
    /// The chart cards: `padding: 20px 24px 14px; gap: 10px`; a 210 pt plot.
    static var chartCardPadding: EdgeInsets { EdgeInsets(top: 20, leading: 24, bottom: 14, trailing: 24) }
    static let chartCardSpacing: CGFloat = 10
    static let chartHeight: CGFloat = 210
    /// A bar is half its day's slot (54.4 of 108.7 pt).
    static let barWidthRatio: Double = 0.5
    /// Axis figures 11 px; dates and bar figures 11.5 px.
    static let axisLabelSize: CGFloat = 11
    static let barLabelSize: CGFloat = 11.5
    /// The Tokens legend: 8 pt dots, 16 pt apart.
    static let legendDotSize: CGFloat = 8
    static let legendSpacing: CGFloat = 16
}

// MARK: - Tooltip

extension HistoryLayout {
    /// The bubble: `rx="12"`, text 14 pt in from its edges, rows 18 pt apart at 12 px.
    static let tooltipRadius: CGFloat = 12
    static var tooltipPadding: EdgeInsets { EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14) }
    static let tooltipRowSpacing: CGFloat = 4
    /// A token row's leading dot, as in the open chat's cells.
    static let tooltipDotSize: CGFloat = 7
    /// How far under the plot's top the bubble sits (`y="40"` over a plot from 24).
    static let tooltipTopInset: CGFloat = 16
}

// MARK: - Quota chart

extension HistoryLayout {
    /// `Dashboard-Quota-History`: the legend over a 380 pt plot (`gap: 12px`), legend
    /// items wrapping `gap: 8px 18px`, 2 pt lines.
    static let quotaChartHeight: CGFloat = 380
    static let quotaCardSpacing: CGFloat = 12
    static let quotaLegendItemWidth: CGFloat = 150
    static let quotaLineWidth: CGFloat = 2
}
