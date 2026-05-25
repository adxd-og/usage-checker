import SwiftUI

struct BarSegment: View {
    let percent: Double
    var height: CGFloat = 8
    var showsLabel: Bool = false

    private var clamped: Double { max(0, min(100, percent)) }

    private var gradient: LinearGradient {
        let colors: [Color]
        if clamped >= 90 {
            colors = [Color.red.opacity(0.85), Color.orange]
        } else if clamped >= 70 {
            colors = [Color.orange, Color.yellow]
        } else if clamped >= 40 {
            colors = [Color.accentColor.opacity(0.9), Color.cyan.opacity(0.85)]
        } else {
            colors = [Color.green.opacity(0.85), Color.mint]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private var labelColor: Color {
        if clamped >= 90 { return .red }
        if clamped >= 70 { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(gradient)
                        .frame(width: geo.size.width * CGFloat(clamped) / 100)
                        .shadow(color: gradient.shadowColor.opacity(0.35), radius: 2, x: 0, y: 0.5)
                }
            }
            .frame(height: height)

            if showsLabel {
                Text("\(Int(clamped.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(labelColor)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

private extension LinearGradient {
    var shadowColor: Color { .accentColor }
}
