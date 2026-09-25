import SwiftUI

/// The Insights tab's measures and colours, from `Dashboard-Insights(-Light).dc.html`.
/// The mockup's weight 650 is `.semibold`.
enum InsightsMetrics {
    // MARK: - Page

    /// Between cards, and between the card row and the strip (`gap: 20px`).
    static let gap: CGFloat = 20
    /// Under the header: `DashboardHeader` pads 12 pt below itself (the literal
    /// `.padding(.bottom, 12)` at `DashboardWindow.swift:136`), and the mockup's cards
    /// start 20 pt under the header row.
    static let headerGap: CGFloat = 8
    /// The detail column's bottom padding (`24px 32px 32px 30px`).
    static let columnBottom: CGFloat = 32
    /// The API-equivalent sentence, or a quota-only provider's reason, under the page:
    /// the figures' caption size, since the mockup has no footnote of its own.
    static let footnoteSize: CGFloat = 12

    // MARK: - Figures, on a card and in the strip

    static let figureCardVerticalPadding: CGFloat = 22
    static let figureCardHorizontalPadding: CGFloat = 24
    static let figureTitleSize: CGFloat = 12.5
    static let figureSpacing: CGFloat = 3
    static let cardValueSize: CGFloat = 30
    static let stripValueSize: CGFloat = 24
    static let figureValueTracking: CGFloat = -0.5
    /// This week vs last's change beside the value.
    static let deltaSize: CGFloat = 13
    static let deltaSpacing: CGFloat = 8
    static let figureCaptionSize: CGFloat = 12
    /// How far a figure may shrink before it truncates, in a column narrower than the
    /// mockup's.
    static let valueMinimumScale: CGFloat = 0.6

    static let stripVerticalPadding: CGFloat = 20
    static let stripHorizontalPadding: CGFloat = 24
    /// Each side of the hairline between two strip figures: the grid's `gap: 24px`, then
    /// the next column's `padding-left: 24px`.
    static let stripColumnGap: CGFloat = 24
    static let stripDividerWidth: CGFloat = 1

    // MARK: - Session window

    static let sessionCardVerticalPadding: CGFloat = 22
    static let sessionCardHorizontalPadding: CGFloat = 26
    static let sessionSpacing: CGFloat = 14
    static let sessionHeaderSpacing: CGFloat = 12
    static let sessionTitleSize: CGFloat = 15
    static let sessionTrailingSize: CGFloat = 12.5
    static let sessionValueSize: CGFloat = 40
    static let sessionValueTracking: CGFloat = -1
    static let sessionValueSpacing: CGFloat = 12
    static let sessionTurnsSize: CGFloat = 13
    static let byProjectSize: CGFloat = 12.5
    static let byProjectTopPadding: CGFloat = 6

    // MARK: - Session window: split by model

    /// The split bar: 10 pt high, rounded 5, 2 pt between models.
    static let splitBarHeight: CGFloat = 10
    static let splitBarRadius: CGFloat = 5
    static let splitBarGap: CGFloat = 2
    /// The legend under it: 22 pt between models, 7 between dot, name and dollars.
    static let legendSpacing: CGFloat = 22
    static let legendItemSpacing: CGFloat = 7
    static let legendDotSize: CGFloat = 8
    static let legendTextSize: CGFloat = 12.5

    /// The models' colours in order: the mockup's blue, violet and teal, which are the
    /// input, cache-write and cache-read token colours in both themes.
    static let modelSplitTokens: [OMColorToken] = [.tokenInput, .tokenCacheWrite, .tokenCacheRead]

    /// The colour of the model at `index`. A fourth would repeat the first, though
    /// `InsightsRules.modelSplitLimit` never asks for one.
    static func modelSplitToken(at index: Int) -> OMColorToken {
        modelSplitTokens[index % modelSplitTokens.count]
    }

    /// The "Other" slice: many models and none in particular, so the muted mark.
    static let otherModelsToken: OMColorToken = .muted

    /// A slice's colour in the bar and the legend: the palette's by position, or
    /// `otherModelsToken` for "Other".
    static func splitToken(for share: InsightsModelShare, at index: Int) -> OMColorToken {
        share.isOther ? otherModelsToken : modelSplitToken(at: index)
    }

    // MARK: - Session window: by project

    /// A project row: the mockup's `170px 1fr 90px 80px` grid, 16 pt apart.
    static let projectNameWidth: CGFloat = 170
    static let projectCostWidth: CGFloat = 90
    static let projectTurnsWidth: CGFloat = 80
    static let projectColumnGap: CGFloat = 16
    static let projectRowVerticalPadding: CGFloat = 10
    static let projectNameSize: CGFloat = 13
    static let projectCostSize: CGFloat = 13.5
    static let projectTurnsSize: CGFloat = 12
    static let projectBarHeight: CGFloat = 6
    /// The hairline between two rows.
    static let projectDividerHeight: CGFloat = 1
}
