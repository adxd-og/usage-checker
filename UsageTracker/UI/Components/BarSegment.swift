import SwiftUI

/// Flat, battery-style level indicator: quiet track, solid status-colored fill,
/// no gradients or glows. An optional pace tick marks how much of the window has
/// elapsed, so the fill reads against "even pace" at a glance.
struct BarSegment: View {
    let percent: Double
    var height: CGFloat = 6
    var showsLabel: Bool = false
    /// 0...1 fraction of the rate-limit window already elapsed. nil hides the tick.
    var pace: Double? = nil

    private var clamped: Double { max(0, min(100, percent)) }
    private var fill: Color { usageStatusColor(clamped) }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.quaternary)
                    Capsule(style: .continuous)
                        .fill(fill)
                        .frame(width: geo.size.width * CGFloat(clamped) / 100)
                    if let pace, pace > 0.02, pace < 0.98 {
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 2, height: height + 4)
                            .offset(x: geo.size.width * CGFloat(pace) - 1)
                    }
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.35), value: clamped)

            if showsLabel {
                Text("\(Int(clamped.rounded()))%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(clamped >= 70 ? AnyShapeStyle(fill) : AnyShapeStyle(.secondary))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(clamped.rounded())) percent used")
    }
}

/// Circular gauge for the headline "how close am I to a limit" number.
struct UsageRing: View {
    let percent: Double
    var size: CGFloat = 52
    var lineWidth: CGFloat = 5

    private var clamped: Double { max(0, min(100, percent)) }
    private var color: Color { usageStatusColor(clamped) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, clamped / 100))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(clamped.rounded()))%")
                .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.35), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(clamped.rounded())) percent used")
    }
}
