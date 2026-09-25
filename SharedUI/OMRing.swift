import SwiftUI

/// Ring gauge: quiet track, status-coloured arc with round caps, optional centre
/// percent and an optional pace marker (a dot on the arc at the fraction of the window
/// already elapsed — usage ahead of the dot is "hot").
///
/// Two looks. `.classic` is the 2.x ring and stays the default: the widget draws it and
/// is untouched in 3.0 (liquid-glass spec § Decisions, "Widget"), and so do the floating
/// window, onboarding and the dashboard until their packages. `.slim` is the 3.0 ring
/// (spec § Components, `OMRing`; `Main.dc.html`, `Popover-Claude.dc.html`): a thinner
/// stroke for its size inside a 1 pt margin, the track, tone and pace-marker tokens,
/// the pace dot on the arc's centre line, and the percent sign set small.
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

    enum Style: Sendable {
        case classic, slim
    }

    /// Everything that sizes one ring in one style.
    struct Metrics: Equatable, Sendable {
        let diameter: CGFloat
        let lineWidth: CGFloat
        let paceDot: CGFloat
        /// How far inside the frame the arc's centre line runs. 0 for classic, whose
        /// stroke is centred on the frame's edge; half the stroke plus 1 pt for slim.
        let arcInset: CGFloat
        /// The arc's ends: round in both styles.
        let lineCap: CGLineCap
        /// The pace dot's opacity over the primary colour (classic, 0.55). Slim's
        /// `paceMarker` token carries its own opacity, so its value is 1 and unused.
        let paceDotOpacity: Double
        /// Slim only: the figure and its "%". Classic uses `Size.labelFont`.
        let labelSize: CGFloat?
        let unitSize: CGFloat?
    }

    /// How much of the window is **used**, 0…100 (anything outside is clamped).
    /// `nil` is "no window at all": the ring draws an empty track and says nothing,
    /// in both modes — a provider that has never reported is not "100% left".
    /// The mode decides what is drawn; the colour never leaves this number.
    let used: Double?
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
    /// Classic unless a 3.0 surface asks for slim.
    var style: Style = .classic
    /// Slim only: last-known numbers — the arc in the muted token and no pace dot.
    var muted: Bool = false

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
        used: Double?, mode: PercentDisplay.Mode, pace: Double? = nil, color: Color? = nil
    ) -> Geometry {
        guard let used else {
            return Geometry(trim: 0, color: color ?? .secondary, label: "—",
                            pace: nil, accessibilityValue: "No data")
        }
        return Geometry(
            trim: max(0.004, PercentDisplay.shown(used, mode: mode) / 100),
            // The one thing that stays on `used`: at 5% left this ring is red,
            // exactly as it is at 95% used.
            color: color ?? usageStatusColor(max(0, min(100, used))),
            label: PercentDisplay.percentText(used, mode: mode),
            pace: PercentDisplay.pace(pace, mode: mode),
            accessibilityValue: PercentDisplay.spoken(used, mode: mode)
        )
    }

    nonisolated static func metrics(size: Size, style: Style) -> Metrics {
        switch style {
        case .classic:
            return Metrics(diameter: size.diameter, lineWidth: size.lineWidth, paceDot: 3,
                           arcInset: 0, lineCap: .round, paceDotOpacity: 0.55,
                           labelSize: nil, unitSize: nil)
        case .slim:
            let (diameter, line, dot, label, unit): (CGFloat, CGFloat, CGFloat, CGFloat?, CGFloat?) = {
                switch size {
                case .widget: return (110, 9, 5, 26, 16)
                case .hero: return (116, 10, 5.6, 28, 18)
                case .medium: return (54, 6, 4, 13, 9)
                case .small: return (44, 4, 3.5, 11, 8)
                case .mini: return (26, 3, 3, nil, nil)
                }
            }()
            return Metrics(diameter: diameter, lineWidth: line, paceDot: dot,
                           arcInset: line / 2 + 1, lineCap: .round, paceDotOpacity: 1,
                           labelSize: label, unitSize: unit)
        }
    }

    /// The radius of the arc's centre line, where the pace dot sits.
    nonisolated static func arcRadius(_ metrics: Metrics) -> CGFloat {
        metrics.diameter / 2 - metrics.arcInset
    }

    /// A dot at the very start or end of a window says nothing, so it is not drawn.
    nonisolated static func paceMarkerVisible(_ pace: Double?) -> Bool {
        guard let pace else { return false }
        return pace > 0.02 && pace < 0.98
    }

    /// The slim arc's colour: the gauge tone's fill on the used value, or the muted
    /// mark for last-known numbers (and for no window at all), which warn of nothing.
    nonisolated static func slimArcToken(used: Double?, muted: Bool) -> OMColorToken {
        guard let used, !muted else { return .muted }
        return OMGaugeTone.forUsed(max(0, min(100, used))).fill
    }

    var body: some View {
        let g = Self.geometry(used: used, mode: mode, pace: pace, color: color)
        let m = Self.metrics(size: size, style: style)
        return ZStack {
            switch style {
            case .classic: classicRing(g, m)
            case .slim: slimRing(g, m)
            }
        }
        .frame(width: m.diameter, height: m.diameter)
        .animation(.smooth(duration: 0.35), value: g.trim)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(g.accessibilityValue)
    }

    /// The 2.x ring, drawn exactly as before.
    @ViewBuilder
    private func classicRing(_ g: Geometry, _ m: Metrics) -> some View {
        Circle()
            .stroke(.quaternary, lineWidth: m.lineWidth)
        Circle()
            .trim(from: 0, to: g.trim)
            .stroke(g.color, style: StrokeStyle(lineWidth: m.lineWidth, lineCap: m.lineCap))
            .rotationEffect(.degrees(-90))
        if let pace = g.pace, Self.paceMarkerVisible(pace) {
            Circle()
                .fill(Color.primary.opacity(m.paceDotOpacity))
                .frame(width: m.paceDot, height: m.paceDot)
                .offset(y: -Self.arcRadius(m))
                .rotationEffect(.degrees(pace * 360))
        }
        if showsLabel, let font = size.labelFont {
            Text(g.label)
                .font(font)
                .monospacedDigit()
        }
    }

    /// The 3.0 ring.
    @ViewBuilder
    private func slimRing(_ g: Geometry, _ m: Metrics) -> some View {
        Circle()
            .inset(by: m.arcInset)
            .stroke(.om(.track), lineWidth: m.lineWidth)
        Circle()
            .inset(by: m.arcInset)
            .trim(from: 0, to: g.trim)
            .stroke(slimArcStyle, style: StrokeStyle(lineWidth: m.lineWidth, lineCap: m.lineCap))
            .rotationEffect(.degrees(-90))
        if !muted, let pace = g.pace, Self.paceMarkerVisible(pace) {
            Circle()
                .fill(.om(.paceMarker))
                .frame(width: m.paceDot, height: m.paceDot)
                .offset(y: -Self.arcRadius(m))
                .rotationEffect(.degrees(pace * 360))
        }
        if showsLabel, let labelSize = m.labelSize, let unitSize = m.unitSize {
            OMFigureText(text: g.label, size: labelSize, unitSize: unitSize)
        }
    }

    /// An explicit `color` still wins, as on the classic ring; otherwise the tone token.
    private var slimArcStyle: AnyShapeStyle {
        if let color { return AnyShapeStyle(color) }
        return AnyShapeStyle(OMColor(Self.slimArcToken(used: used, muted: muted)))
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

#Preview("Rings — slim") {
    HStack(spacing: 16) {
        OMRing(used: 53, mode: .used, size: .hero, pace: 0.45, style: .slim)
        OMRing(used: 57, mode: .used, size: .medium, pace: 0.96, style: .slim)
        OMRing(used: 21, mode: .used, size: .medium, pace: 0.5, style: .slim, muted: true)
    }
    .padding()
    .preferredColorScheme(.dark)
}
