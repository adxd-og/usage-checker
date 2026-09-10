import SwiftUI

/// Flat, battery-style level indicator: quiet track, solid status-colored fill,
/// no gradients or glows. An optional pace tick marks how much of the window has
/// elapsed, so the fill reads against "even pace" at a glance.
struct BarSegment: View {
    /// How much of the window is **used**, 0…100. See `OMRing.used`.
    let used: Double
    let mode: PercentDisplay.Mode
    var height: CGFloat = 6
    var showsLabel: Bool = false
    /// 0...1 fraction of the rate-limit window already elapsed. nil hides the tick.
    var pace: Double? = nil

    /// Everything the bar draws. Same split, and same reason, as `OMRing.Geometry`.
    struct Geometry: Equatable {
        let fillFraction: Double
        let color: Color
        let label: String
        /// The label goes coloured near the limit — the same warning the fill gives,
        /// so it is decided on the used value whichever way the number counts.
        let labelIsColored: Bool
        let pace: Double?
        let accessibilityValue: String
    }

    nonisolated static func geometry(
        used: Double, mode: PercentDisplay.Mode, pace: Double? = nil
    ) -> Geometry {
        let usedClamped = max(0, min(100, used))
        return Geometry(
            fillFraction: PercentDisplay.shown(used, mode: mode) / 100,
            color: usageStatusColor(usedClamped),
            label: PercentDisplay.percentText(used, mode: mode),
            labelIsColored: usedClamped >= 70,
            pace: PercentDisplay.pace(pace, mode: mode),
            accessibilityValue: PercentDisplay.spoken(used, mode: mode)
        )
    }

    var body: some View {
        let g = Self.geometry(used: used, mode: mode, pace: pace)
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.quaternary)
                    Capsule(style: .continuous)
                        .fill(g.color)
                        .frame(width: geo.size.width * CGFloat(g.fillFraction))
                    if let pace = g.pace, pace > 0.02, pace < 0.98 {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 2, height: height + 4)
                            .offset(x: geo.size.width * CGFloat(pace) - 1)
                    }
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.35), value: g.fillFraction)

            if showsLabel {
                Text(g.label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(g.labelIsColored ? AnyShapeStyle(g.color) : AnyShapeStyle(.secondary))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(g.accessibilityValue)
    }
}
