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
