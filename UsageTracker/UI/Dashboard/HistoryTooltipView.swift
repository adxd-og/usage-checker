import SwiftUI

/// The chart tooltip's bubble (liquid-glass spec § Components, "Chart tooltip"): the
/// title and, in Tokens mode, the day's total on its right; then one row per figure.
/// Its words come from `HistoryTooltipRules`.
struct HistoryTooltipView: View {
    let tooltip: HistoryTooltip
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryLayout.tooltipRowSpacing) {
            HStack(spacing: 8) {
                Text(tooltip.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.om(.text))
                Spacer(minLength: 8)
                if let headline = tooltip.headline {
                    Text(headline)
                        .font(OMFont.numerals(size: 12, weight: .semibold))
                        .foregroundStyle(.om(.text))
                }
            }
            ForEach(Array(tooltip.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    if let token = row.token {
                        Circle()
                            .fill(.om(token))
                            .frame(width: HistoryLayout.tooltipDotSize, height: HistoryLayout.tooltipDotSize)
                    }
                    Text(row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(OMFont.numerals(size: 12, weight: .semibold))
                        .foregroundStyle(.om(.text))
                }
            }
        }
        .padding(HistoryLayout.tooltipPadding)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HistoryLayout.tooltipRadius, style: .continuous)
                .fill(.om(.tooltipFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HistoryLayout.tooltipRadius, style: .continuous)
                .strokeBorder(.om(.tooltipBorder), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
