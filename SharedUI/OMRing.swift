import SwiftUI

/// Ring gauge: quiet track, status-coloured arc with round caps, optional
/// centre percent and an optional pace marker (a dot on the track at the
/// fraction of the window already elapsed — usage ahead of the dot is "hot").
struct OMRing: View {
    enum Size {
        /// The desktop widget's small family: one ring filling the tile.
        case widget
        case hero, medium, small, mini

        var diameter: CGFloat {
            switch self {
            case .widget: 110
            case .hero: 84
            case .medium: 52
            case .small: 44
            case .mini: 26
            }
        }
        var lineWidth: CGFloat {
            switch self {
            case .widget: 10
            case .hero: 9
            case .medium: 6
            case .small: 5
            case .mini: 4
            }
        }
        var labelFont: Font? {
            switch self {
            case .widget: OMFont.heroNumeral
            case .hero: OMFont.heroNumeral
            case .medium: OMFont.numeral
            case .small: Font.system(size: 11, weight: .bold, design: .rounded)
            case .mini: nil
            }
        }
    }

    /// How much of the window is **used**, 0…100 (anything outside is clamped).
    /// The mode decides what is drawn; the colour never leaves this number.
    let used: Double
    /// Which way this ring counts. Deliberately without a default: every call site
    /// has to say, so a new gauge cannot quietly ignore the user's choice.
    let mode: PercentDisplay.Mode
    var size: Size = .medium
    /// 0…1 fraction of the window already elapsed. Mirrored for `remaining` inside
    /// `geometry`, never here.
    var pace: Double? = nil
    var color: Color? = nil
    /// The widget draws its own centre stack over the ring; `false` stops OMRing
    /// from stacking a second numeral underneath it.
    var showsLabel: Bool = true

    /// Everything the ring draws, decided in one place: the arc, its colour, the
    /// centre label, where the pace dot sits and what VoiceOver says.
    struct Geometry: Equatable {
        let trim: Double
        let color: Color
        let label: String
        let pace: Double?
        let accessibilityValue: String
    }

    nonisolated static func geometry(
        used: Double, mode: PercentDisplay.Mode, pace: Double? = nil, color: Color? = nil
    ) -> Geometry {
        Geometry(
            trim: max(0.004, PercentDisplay.shown(used, mode: mode) / 100),
            // The one thing that stays on `used`: at 5% left this ring is red,
            // exactly as it is at 95% used.
            color: color ?? usageStatusColor(max(0, min(100, used))),
            label: PercentDisplay.percentText(used, mode: mode),
            pace: PercentDisplay.pace(pace, mode: mode),
            accessibilityValue: PercentDisplay.spoken(used, mode: mode)
        )
    }

    var body: some View {
        let g = Self.geometry(used: used, mode: mode, pace: pace, color: color)
        return ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: size.lineWidth)
            Circle()
                .trim(from: 0, to: g.trim)
                .stroke(g.color, style: StrokeStyle(lineWidth: size.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let pace = g.pace, pace > 0.02, pace < 0.98 {
                Circle()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: 3, height: 3)
                    .offset(y: -(size.diameter / 2))
                    .rotationEffect(.degrees(pace * 360))
            }
            if showsLabel, let font = size.labelFont {
                Text(g.label)
                    .font(font)
                    .monospacedDigit()
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .animation(.smooth(duration: 0.35), value: g.trim)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(g.accessibilityValue)
    }
}

#Preview("Rings — light") {
    HStack(spacing: 16) {
        OMRing(used: 37, mode: .used, size: .hero, pace: 0.45)
        OMRing(used: 74, mode: .used, size: .medium)
        OMRing(used: 92, mode: .used, size: .small)
        OMRing(used: 12, mode: .used, size: .mini)
    }
    .padding()
}

#Preview("Rings — dark") {
    HStack(spacing: 16) {
        OMRing(used: 37, mode: .used, size: .hero, pace: 0.45)
        OMRing(used: 74, mode: .used, size: .medium)
        OMRing(used: 92, mode: .used, size: .small)
        OMRing(used: 12, mode: .used, size: .mini)
    }
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Ring — widget size") {
    HStack(spacing: 16) {
        OMRing(used: 42, mode: .used, size: .widget)
        OMRing(used: 42, mode: .used, size: .widget, showsLabel: false)
    }
    .padding()
}
