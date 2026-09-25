import SwiftUI

/// Flat, battery-style level indicator: quiet track, solid status-coloured fill, no
/// gradients or glows. An optional pace tick marks how much of the window has elapsed,
/// so the fill reads against "even pace" at a glance.
///
/// `.classic` is the 2.x bar and the default, because the widget draws it and is
/// untouched in 3.0. `.slim` is the 3.0 bar (`Popover-Claude.dc.html`): the track, tone
/// and pace-marker tokens and a tick that stands 3 pt proud of the bar on each side.
struct BarSegment: View {
    enum Style: Sendable {
        case classic, slim
    }

    /// How much of the window is **used**, 0…100. See `OMRing.used`.
    let used: Double
    let mode: PercentDisplay.Mode
    var height: CGFloat = 6
    var showsLabel: Bool = false
    /// 0...1 fraction of the rate-limit window already elapsed. nil hides the tick.
    var pace: Double? = nil
    var style: Style = .classic

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

    /// The pace tick: classic 2 pt × (height + 4); slim 2 pt × (height + 6).
    nonisolated static func tickHeight(barHeight: CGFloat, style: Style) -> CGFloat {
        style == .slim ? barHeight + 6 : barHeight + 4
    }

    /// The pace tick is 2 pt wide, a capsule, in both styles.
    nonisolated static let tickWidth: CGFloat = 2
    nonisolated static let tickCorner: OMCorner = .capsule
    /// The classic tick's opacity over the primary colour. Slim's `paceMarker` token
    /// carries its own.
    nonisolated static let classicTickOpacity: Double = 0.45

    /// A tick at the very start or end of a window says nothing, so it is not drawn.
    nonisolated static func tickVisible(_ pace: Double?) -> Bool {
        guard let pace else { return false }
        return pace > 0.02 && pace < 0.98
    }

    /// The slim fill: the gauge tone's token on the used value.
    nonisolated static func slimFillToken(used: Double) -> OMColorToken {
        OMGaugeTone.forUsed(max(0, min(100, used))).fill
    }

    var body: some View {
        let g = Self.geometry(used: used, mode: mode, pace: pace)
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(trackStyle)
                    Capsule(style: .continuous)
                        .fill(fillStyle(g))
                        .frame(width: geo.size.width * CGFloat(g.fillFraction))
                    if let pace = g.pace, Self.tickVisible(pace) {
                        tick
                            .frame(width: Self.tickWidth, height: Self.tickHeight(barHeight: height, style: style))
                            .offset(x: geo.size.width * CGFloat(pace) - Self.tickWidth / 2)
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

    private var trackStyle: AnyShapeStyle {
        style == .slim ? AnyShapeStyle(OMColor(.track)) : AnyShapeStyle(.quaternary)
    }

    private func fillStyle(_ g: Geometry) -> AnyShapeStyle {
        style == .slim ? AnyShapeStyle(OMColor(Self.slimFillToken(used: used))) : AnyShapeStyle(g.color)
    }

    private var tickStyle: AnyShapeStyle {
        style == .slim ? AnyShapeStyle(OMColor(.paceMarker)) : AnyShapeStyle(Color.primary.opacity(Self.classicTickOpacity))
    }

    /// The tick in its rule's shape: a capsule today, as it always was.
    @ViewBuilder
    private var tick: some View {
        switch Self.tickCorner {
        case .capsule:
            Capsule(style: .continuous).fill(tickStyle)
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tickStyle)
        }
    }
}
