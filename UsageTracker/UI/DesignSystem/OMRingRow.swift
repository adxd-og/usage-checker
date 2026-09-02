import SwiftUI

/// Weekly / model-scoped windows as a grid of small rings. Four per row; an
/// untouched window keeps its ring (so the grid stays aligned) but dims.
struct OMRingRow: View {
    let buckets: [UsageBucket]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: OMSpacing.s), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: OMSpacing.m) {
            ForEach(buckets) { bucket in
                VStack(spacing: 5) {
                    OMRing(percent: bucket.clampedPercent, size: .small, pace: bucket.elapsedFraction())
                    Text(WindowRanking.shortWindowLabel(bucket.label))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .opacity(bucket.clampedPercent == 0 ? 0.55 : 1)
                .help(helpText(bucket))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(bucket.label), \(Int(bucket.clampedPercent.rounded())) percent used")
            }
        }
    }

    private func helpText(_ bucket: UsageBucket) -> String {
        if bucket.resetsAt < .distantFuture {
            return "\(bucket.label) · resets \(bucket.resetsAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return bucket.label
    }
}

#Preview("Ring row") {
    let mk = { (id: String, label: String, p: Double) in
        UsageBucket(id: id, label: label, utilization: p, resetsAt: Date().addingTimeInterval(86400 * 3), kind: .weekly)
    }
    return OMRingRow(buckets: [mk("seven_day", "All models", 52), mk("seven_day_fable", "Fable only", 12), mk("seven_day_opus", "Opus only", 8), mk("seven_day_sonnet", "Sonnet only", 74), mk("seven_day_haiku", "Haiku only", 0)])
        .padding().frame(width: 328)
}
