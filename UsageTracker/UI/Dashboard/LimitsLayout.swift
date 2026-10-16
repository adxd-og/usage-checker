import SwiftUI

/// The Limits tab's measurements, from `Dashboard-Limits(-Light).dc.html` (spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab). Numbers only, and
/// the one width decision the ranked list takes; the views read them. The mockup's
/// weight 650 is `.semibold`.
enum LimitsLayout {}

// MARK: - Page

extension LimitsLayout {
    /// The mockup's 20 pt between the title and the controls row, less the 12 pt
    /// `DashboardHeader` leaves under itself.
    static let controlsTopPadding: CGFloat = 8
    /// Between the controls in the row (`gap: 10px`).
    static let controlSpacing: CGFloat = 10
    /// Between the controls row and the cards, and between cards (`gap: 20px`).
    static let sectionSpacing: CGFloat = 20
    /// The detail column's bottom padding (`24px 32px 32px 30px`).
    static let columnBottom: CGFloat = 32
    /// A page with no cards: its one sentence on a card, and the budget link under it
    /// where there is one.
    static let messageSize: CGFloat = 13
    static let messagePadding: CGFloat = 20
    static let messageSpacing: CGFloat = 10
}

// MARK: - Cards

extension LimitsLayout {
    /// A card's title ("Price of a percent", "What filled this week": 15 px, 650) and the
    /// caption on its baseline (12.5 px).
    static let cardTitleSize: CGFloat = 15
    static let cardCaptionSize: CGFloat = 12.5
    /// Between a card's title and what sits at its trailing edge (`gap: 12px`).
    static let titleSpacing: CGFloat = 12
    /// The line between two rows.
    static let hairlineHeight: CGFloat = 1
}

// MARK: - The first card

extension LimitsLayout {
    /// `padding: 22px 26px; gap: 12px`.
    static let topCardVerticalPadding: CGFloat = 22
    static let topCardHorizontalPadding: CGFloat = 26
    static let topCardSpacing: CGFloat = 12
    /// "1 % ≈ $62": 40 px rounded, 700, `letter-spacing: -1px`; its tokens 13 px beside it
    /// (`gap: 12px`); the caption 12 px under them (`gap: 2px`).
    static let figureSize: CGFloat = 40
    static let figureTracking: CGFloat = -1
    static let figureSpacing: CGFloat = 12
    static let figureDetailSize: CGFloat = 13
    static let figureCaptionSize: CGFloat = 12
    static let figureCaptionSpacing: CGFloat = 2
    /// How far the figure may shrink before it truncates, in a card narrower than the
    /// mockup's.
    static let figureScaleFloor: CGFloat = 0.6
    /// "Not enough use yet" in the figure's place: a sentence, not a number.
    static let sentenceSize: CGFloat = 15
}

// MARK: - The ranked list

extension LimitsLayout {
    /// `padding: 20px 24px 8px`; the header row's `padding-bottom: 12px`; the title and its
    /// caption `gap: 10px`.
    static var rankedCardPadding: EdgeInsets { EdgeInsets(top: 20, leading: 24, bottom: 8, trailing: 24) }
    static let cardHorizontalPadding: CGFloat = 24
    static let rankedHeaderBottom: CGFloat = 12
    static let rankedTitleSpacing: CGFloat = 10
    /// A row `padding: 10px 0`; Outside's `11px 0`; a name over its project `gap: 2px`.
    static let rowVerticalPadding: CGFloat = 10
    static let tailRowVerticalPadding: CGFloat = 11
    static let rowLineSpacing: CGFloat = 2
    /// The name 13.5 px 650, the project 12 px, the share 14.5 px rounded 700, the dollars
    /// 13.5 px rounded 600.
    static let rowTitleSize: CGFloat = 13.5
    static let rowSubtitleSize: CGFloat = 12
    static let rowShareSize: CGFloat = 14.5
    static let rowDollarsSize: CGFloat = 13.5
    // The row's grid: `minmax(0, 1fr) 280px 96px 80px`, `column-gap: 18px`.
    static let columnGap: CGFloat = 18
    /// The least a chat's name keeps before the row folds: History's figure (the mockup's
    /// `minmax(0, 1fr)` has no floor).
    static let titleMinWidth: CGFloat = 160
    static let projectWidth: CGFloat = 280
    static let shareWidth: CGFloat = 96
    static let dollarsWidth: CGFloat = 80

    /// The width the wide row needs: its four columns and three gaps.
    static var wideRowsMinWidth: CGFloat {
        titleMinWidth + projectWidth + shareWidth + dollarsWidth + 3 * columnGap
    }

    /// The rows' width inside a detail column this wide: the column's gutters and the
    /// card's own padding come off.
    static func rowsWidth(detailWidth: CGFloat) -> CGFloat {
        detailWidth - DashboardShellLayout.columnLeading - DashboardShellLayout.columnTrailing
            - 2 * cardHorizontalPadding
    }

    /// Whether a row gives the project its own column. Below this the project goes under
    /// the name. The page measures it once for every row.
    static func isWideRows(detailWidth: CGFloat) -> Bool {
        rowsWidth(detailWidth: detailWidth) >= wideRowsMinWidth
    }
}
