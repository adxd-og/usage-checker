import SwiftUI

/// "Extra usage   $12.40 / $50" with an optional level bar underneath.
struct OMKeyValueRow: View {
    let label: String
    let value: String
    var barPercent: Double? = nil
    /// 0…1 fraction of the window already elapsed — the bar's pace tick.
    var pace: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(OMFont.bodyStrong)
                Spacer()
                Text(value)
                    .font(OMFont.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let barPercent {
                BarSegment(percent: barPercent, height: 6, showsLabel: false, pace: pace)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

#Preview {
    VStack(spacing: 12) {
        OMKeyValueRow(label: "Extra usage credits", value: "$12.40 / $50", barPercent: 25)
        OMKeyValueRow(label: "Last 7 days", value: "$15.60")
    }
    .padding().frame(width: 328)
}
