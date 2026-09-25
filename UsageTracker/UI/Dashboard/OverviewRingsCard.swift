import SwiftUI

/// Three concentric rings, one per window (the first three), with a window's figure and
/// short name in the middle (liquid-glass spec § Components, "Overview rings"). Draws what
/// it is given; `OverviewRingsCard` decides which window is emphasised.
struct OverviewRings: View {
    let windows: [OverviewRingWindow]
    let mode: PercentDisplay.Mode
    /// Last-known numbers: no pace dots.
    let retained: Bool
    /// One per window; a ring past the end of the list draws at full strength.
    let opacities: [Double]
    let centre: OverviewRingsRules.Centre?
    let now: Date

    var body: some View {
        ZStack {
            ForEach(Array(windows.prefix(OverviewRingsRules.radii.count).enumerated()), id: \.element.id) { index, window in
                ring(window, radius: OverviewRingsRules.radii[index])
                    .opacity(index < opacities.count ? opacities[index] : 1)
            }
            if let centre {
                VStack(spacing: 0) {
                    OMFigureText(
                        text: centre.percent,
                        size: OverviewRingsRules.centreFigureSize,
                        unitSize: OverviewRingsRules.centreUnitSize
                    )
                    Text(centre.name)
                        .font(.system(size: OverviewRingsRules.centreLabelSize))
                        .foregroundStyle(.om(.secondary))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(width: OverviewRingsRules.centreWidth)
                .allowsHitTesting(false)
            }
        }
        .frame(width: OverviewRingsRules.diameter, height: OverviewRingsRules.diameter)
        // The legend rows say all of this in words.
        .accessibilityHidden(true)
    }

    /// One ring: its track in its own colour at 16 %, the arc with round caps from twelve
    /// o'clock and the pace dot on the arc's centre line. `OMRing`'s geometry, so this ring
    /// and the popover's agree on the same window in either percent mode.
    private func ring(_ window: OverviewRingWindow, radius: CGFloat) -> some View {
        let token = window.series ?? .muted
        let geometry = OMRing.geometry(
            used: window.bucket.clampedPercent,
            mode: mode,
            pace: window.bucket.elapsedFraction(now: now)
        )
        return ZStack {
            Circle()
                .stroke(OMColor(token).opacity(OverviewRingsRules.trackOpacity), lineWidth: OverviewRingsRules.lineWidth)
            Circle()
                .trim(from: 0, to: geometry.trim)
                .stroke(OMColor(token), style: StrokeStyle(lineWidth: OverviewRingsRules.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if OverviewRingsRules.showsPaceDot(pace: geometry.pace, retained: retained), let pace = geometry.pace {
                Circle()
                    .fill(.om(.paceMarker))
                    .frame(width: OverviewRingsRules.paceDotDiameter, height: OverviewRingsRules.paceDotDiameter)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(pace * 360))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

/// The Overview's first card (spec § Screens, "Overview"): the rings beside a legend that
/// names each window, when it resets and how full it is (the rows the 2.x Overview listed
/// under its hero), titled with the worst limit's verdict and closed by the burn rate.
struct OverviewRingsCard: View {
    let service: ServiceSnapshot
    let mode: PercentDisplay.Mode
    /// The legend's last line: the burn verdict, or "Burn rate: idle".
    let footer: OverviewLine
    /// Last-known numbers: when they were true and why they stopped (`RetainedCopy`).
    let retainedCaption: String?

    var body: some View {
        let now = Date()
        let windows = OverviewRingsRules.windows(for: service)
        HStack(alignment: .center, spacing: OverviewRingsRules.ringLegendSpacing) {
            OverviewRings(
                windows: windows,
                mode: mode,
                retained: service.isRetained,
                opacities: windows.map { _ in 1 },
                centre: OverviewRingsRules.centre(windows: windows, emphasised: nil, mode: mode),
                now: now
            )
            .opacity(service.isRetained ? OverviewRingsRules.retainedOpacity : 1)
            legend(windows, now: now)
        }
        .padding(.vertical, OverviewRingsRules.cardVerticalPadding)
        .padding(.horizontal, OverviewRingsRules.cardHorizontalPadding)
        .frame(maxHeight: .infinity, alignment: .center)
        .dashboardCard(padding: 0)
    }

    private func legend(_ windows: [OverviewRingWindow], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(OverviewCopy.legendTitle)
                    .font(.system(size: OverviewRingsRules.legendTitleSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                Spacer(minLength: 0)
                if let status = OverviewRingsRules.status(for: service) {
                    Text(status.text)
                        .font(.system(size: OverviewRingsRules.statusSize, weight: .semibold))
                        .foregroundStyle(.om(status.token))
                }
            }
            .padding(.bottom, OverviewRingsRules.legendTitleBottomPadding)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 {
                        Rectangle()
                            .fill(.om(.hairline))
                            .frame(height: 1)
                    }
                    row(window, now: now)
                }
            }
            .opacity(service.isRetained ? OverviewRingsRules.retainedOpacity : 1)
            Text(footer.text)
                .font(.system(size: OverviewRingsRules.footerSize))
                .foregroundStyle(.om(footer.token))
                .padding(.top, OverviewRingsRules.footerTopPadding)
            if let retainedCaption {
                Text(retainedCaption)
                    .font(.system(size: OverviewRingsRules.footerSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, OverviewRingsRules.footerTopPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ window: OverviewRingWindow, now: Date) -> some View {
        let subline = OverviewRingsRules.subline(for: window.bucket, service: service, now: now)
        return HStack(alignment: .center, spacing: OverviewRingsRules.rowSpacing) {
            Circle()
                .fill(OMColor(window.series ?? .muted))
                .frame(width: OverviewRingsRules.rowDotDiameter, height: OverviewRingsRules.rowDotDiameter)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.bucket.label)
                    .font(.system(size: OverviewRingsRules.rowNameSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                if let subline {
                    Text(subline)
                        .font(.system(size: OverviewRingsRules.rowSublineSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            OMFigureText(
                text: PercentDisplay.percentText(window.bucket.clampedPercent, mode: mode),
                size: OverviewRingsRules.rowFigureSize,
                unitSize: OverviewRingsRules.rowUnitSize
            )
        }
        .padding(.vertical, OverviewRingsRules.rowVerticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OverviewRingsRules.accessibilityLabel(for: window.bucket, subline: subline, mode: mode))
    }
}
