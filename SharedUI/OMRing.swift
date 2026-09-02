import SwiftUI

/// Ring gauge: quiet track, status-coloured arc with round caps, optional
/// centre percent and an optional pace marker (a dot on the track at the
/// fraction of the window already elapsed — usage ahead of the dot is "hot").
struct OMRing: View {
    enum Size {
        case hero, medium, small, mini

        var diameter: CGFloat {
            switch self {
            case .hero: 84
            case .medium: 52
            case .small: 44
            case .mini: 26
            }
        }
        var lineWidth: CGFloat {
            switch self {
            case .hero: 9
            case .medium: 6
            case .small: 5
            case .mini: 4
            }
        }
        var labelFont: Font? {
            switch self {
            case .hero: OMFont.heroNumeral
            case .medium: OMFont.numeral
            case .small: Font.system(size: 11, weight: .bold, design: .rounded)
            case .mini: nil
            }
        }
    }

    let percent: Double
    var size: Size = .medium
    var pace: Double? = nil
    var color: Color? = nil

    private var clamped: Double { max(0, min(100, percent)) }
    private var arcColor: Color { color ?? usageStatusColor(clamped) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: size.lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, clamped / 100))
                .stroke(arcColor, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let pace, pace > 0.02, pace < 0.98 {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 3, height: 3)
                    .offset(y: -(size.diameter / 2))
                    .rotationEffect(.degrees(pace * 360))
            }
            if let font = size.labelFont {
                Text("\(Int(clamped.rounded()))%")
                    .font(font)
                    .monospacedDigit()
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .animation(.smooth(duration: 0.35), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(clamped.rounded())) percent used")
    }
}

#Preview("Rings — light") {
    HStack(spacing: 16) {
        OMRing(percent: 37, size: .hero, pace: 0.45)
        OMRing(percent: 74, size: .medium)
        OMRing(percent: 92, size: .small)
        OMRing(percent: 12, size: .mini)
    }
    .padding()
}

#Preview("Rings — dark") {
    HStack(spacing: 16) {
        OMRing(percent: 37, size: .hero, pace: 0.45)
        OMRing(percent: 74, size: .medium)
        OMRing(percent: 92, size: .small)
        OMRing(percent: 12, size: .mini)
    }
    .padding()
    .preferredColorScheme(.dark)
}
