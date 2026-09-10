import SwiftUI

/// "Extra usage   $12.40 / $50" with an optional level bar underneath.
struct OMKeyValueRow: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(OMFont.bodyStrong)
                Spacer()
                Text(value)
                    .font(OMFont.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The reset text grew a "(13:00)". One line is what guarantees
                    // every row stays exactly the height it was.
                    .lineLimit(1)
            }
            if let barUsedPercent {
                BarSegment(used: barUsedPercent, mode: barMode, height: 6, showsLabel: false, pace: pace)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
        .help(help ?? "")
    }
}

#Preview {
    VStack(spacing: 12) {
        OMKeyValueRow(label: "Extra usage credits", value: "$12.40 / $50", barUsedPercent: 25)
        OMKeyValueRow(label: "Last 7 days", value: "$15.60")
    }
    .padding().frame(width: 328)
}
