import SwiftUI

/// The Limits tab's first card (`Dashboard-Limits(-Light).dc.html`, "Price of a
/// percent"): a title with the period's start on its baseline, the mode's figure, what
/// its dollars are, and for pay as you go on Claude a link to the weekly budget in
/// Settings. The words are `LimitsCopy.topCard`'s.
struct LimitsTopCard: View {
    let text: LimitsTopCardText
    /// Opens Settings on the weekly budget.
    let onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LimitsLayout.topCardSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: LimitsLayout.titleSpacing) {
                Text(text.title)
                    .font(.system(size: LimitsLayout.cardTitleSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LimitsLayout.titleSpacing)
                Text(text.trailing)
                    .font(.system(size: LimitsLayout.cardCaptionSize))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: LimitsLayout.figureCaptionSpacing) {
                // The figure and its tokens on one baseline where they fit, stacked where
                // the card is too narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: LimitsLayout.figureSpacing) {
                        value
                        detail
                    }
                    VStack(alignment: .leading, spacing: LimitsLayout.figureCaptionSpacing) {
                        value
                        detail
                    }
                }
                .accessibilityElement(children: .combine)
                if let caption = text.caption {
                    Text(caption)
                        .font(.system(size: LimitsLayout.figureCaptionSize))
                        .foregroundStyle(.om(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let link = text.link {
                Button(link, action: onLink)
                    .buttonStyle(.omLink)
            }
        }
        // `dashboardCard(padding:)` pads all four sides alike; the mockup pads the sides
        // more than the top and bottom.
        .padding(.horizontal, LimitsLayout.topCardHorizontalPadding - LimitsLayout.topCardVerticalPadding)
        .dashboardCard(padding: LimitsLayout.topCardVerticalPadding)
    }

    @ViewBuilder
    private var value: some View {
        if text.valueIsFigure {
            Text(text.value)
                .font(OMFont.numerals(size: LimitsLayout.figureSize, weight: .bold))
                .tracking(LimitsLayout.figureTracking)
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .minimumScaleFactor(LimitsLayout.figureScaleFloor)
        } else {
            Text(text.value)
                .font(.system(size: LimitsLayout.sentenceSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = text.detail {
            Text(detail)
                .font(.system(size: LimitsLayout.figureDetailSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
        }
    }
}
