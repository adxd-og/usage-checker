import SwiftUI

/// "Extra usage   $12.40 / $50" or "All models   41%", with an optional level bar under
/// it (`Popover-Claude.dc.html`'s weekly rows).
struct OMKeyValueRow: View {
    /// How the value is set: a caption ("resets in 2h (13:00)", "$12.40 / $50") or a
    /// figure ("41%") in rounded numerals with its unit small.
    enum ValueStyle: Sendable {
        case caption, figure
    }

    let label: String
    let value: String
    /// The bar's **used** value, 0…100. nil means the row has no bar.
    var barUsedPercent: Double? = nil
    /// Which way that bar counts. Defaulted, because most rows here have no bar at
    /// all; the rename above is what forces every row that does into the diff.
    var barMode: PercentDisplay.Mode = .used
    /// 0…1 fraction of the window already elapsed — the bar's pace tick.
    var pace: Double? = nil
    /// Tooltip for a row whose value is a countdown: the exact reset time. An empty
    /// string is how AppKit spells "no tooltip", so nil rows keep behaving as before
    /// without a second view identity.
    var help: String? = nil
    var valueStyle: ValueStyle = .caption
    /// What VoiceOver reads for the row; nil reads "label, value".
    var accessibilityText: String? = nil

    // MARK: - Metrics (`Popover-Claude.dc.html`)

    nonisolated static let labelSize: CGFloat = 12.5
    nonisolated static let captionSize: CGFloat = 12.5
    nonisolated static let figureSize: CGFloat = 14
    nonisolated static let figureUnitSize: CGFloat = 9
    nonisolated static let barHeight: CGFloat = 6
    nonisolated static let barSpacing: CGFloat = 7
    nonisolated static var barStyle: BarSegment.Style { .slim }

    nonisolated static func spokenText(label: String, value: String, override: String?) -> String {
        override ?? "\(label), \(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.barSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: Self.labelSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                Spacer()
                switch valueStyle {
                case .caption:
                    Text(value)
                        .font(.system(size: Self.captionSize))
                        .monospacedDigit()
                        .foregroundStyle(.om(.secondary))
                        // The reset text grew a "(13:00)". One line is what guarantees
                        // every row stays exactly the height it was.
                        .lineLimit(1)
                case .figure:
                    OMFigureText(text: value, size: Self.figureSize, unitSize: Self.figureUnitSize)
                }
            }
            if let barUsedPercent {
                BarSegment(used: barUsedPercent, mode: barMode, height: Self.barHeight, showsLabel: false,
                           pace: pace, style: Self.barStyle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spokenText(label: label, value: value, override: accessibilityText))
        .help(help ?? "")
    }
}

#Preview {
    VStack(spacing: 14) {
        OMKeyValueRow(label: "All models", value: "41%", barUsedPercent: 41, pace: 0.45, valueStyle: .figure)
        OMKeyValueRow(label: "Extra usage credits", value: "$12.40 / $50", barUsedPercent: 25)
        OMKeyValueRow(label: "Last 7 days", value: "$15.60", valueStyle: .figure)
    }
    .padding().frame(width: 332)
}
