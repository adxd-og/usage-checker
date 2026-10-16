import SwiftUI
import Charts

/// "Timeline" (spec 2026-10-16 limit analytics § The tab, item 4;
/// `Dashboard-Limits(-Light).dc.html`): one bar per half hour of the window that moved,
/// stacked by its five largest projects, Other and Outside this Mac; hovering a bar names
/// its half hour and its split. The bars are `LimitsRules.timeline`'s and the words
/// `LimitsCopy`'s; colours from the 3.0 tokens, resolved for the window's appearance
/// because Charts takes a `Color`.
struct LimitsTimelineCard: View {
    let load: DashboardState.LimitShareLoad
    /// The window's length, for the x axis' marks.
    let span: LimitsSpan

    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current
    /// Built off the main actor when the share changes (`LimitsCardKey`), never in
    /// `body`: a week has 336 half hours, and naming their projects reads the disk.
    @State private var timeline: LimitsTimeline?
    /// The bar under the pointer.
    @State private var hovered: LimitsTimelineBar?

    var body: some View {
        VStack(alignment: .leading, spacing: LimitsLayout.timelineCardSpacing) {
            header
            if let timeline {
                chart(timeline)
                    .frame(height: LimitsLayout.timelineHeight)
                legend(timeline)
            }
        }
        .padding(LimitsLayout.timelineCardPadding)
        .dashboardCard(padding: 0)
        .task(id: load.cardKey) {
            await build()
        }
    }

    /// The timeline of the share on screen, built on a detached task. A newer share's
    /// build cancels this one, which then publishes nothing.
    private func build() async {
        let share = load.share
        let serviceID = load.serviceID
        let built = await Task.detached(priority: .userInitiated) {
            LimitsRules.timeline(of: share, serviceID: serviceID)
        }.value
        guard !Task.isCancelled else { return }
        timeline = built
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LimitsLayout.titleSpacing) {
            Text(LimitsCopy.timelineTitle)
                .font(.system(size: LimitsLayout.cardTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LimitsLayout.titleSpacing)
            Text(LimitsCopy.timelineCaption)
                .font(.system(size: LimitsLayout.cardCaptionSize))
                .foregroundStyle(.om(.secondary))
        }
    }

    private func chart(_ timeline: LimitsTimeline) -> some View {
        let tokens = Dictionary(timeline.series.map { ($0.id, $0.token) }, uniquingKeysWith: { first, _ in first })
        let top = timeline.axis.last ?? 1
        let stride = LimitsRules.timelineStride(span: span)
        return Chart {
            if let hovered {
                RectangleMark(
                    xStart: .value("Start", hovered.start),
                    xEnd: .value("End", hovered.end),
                    yStart: .value("Points", 0.0),
                    yEnd: .value("Points", top)
                )
                .foregroundStyle(color(.track))
            }
            ForEach(timeline.bars) { bar in
                let inset = LimitsRules.barInset(bar)
                ForEach(bar.parts, id: \.seriesID) { part in
                    RectangleMark(
                        xStart: .value("Start", bar.start.addingTimeInterval(inset)),
                        xEnd: .value("End", bar.end.addingTimeInterval(-inset)),
                        yStart: .value("Points", part.base),
                        yEnd: .value("Points", part.top)
                    )
                    .foregroundStyle(color(tokens[part.seriesID] ?? LimitsRules.otherSeriesToken))
                }
            }
        }
        .chartXScale(domain: load.share.window.start...load.share.window.end)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: .stride(by: stride.component, count: stride.count)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color(.hairline))
                AxisValueLabel(centered: span != .session) {
                    if let date = value.as(Date.self) {
                        Text(LimitsCopy.timelineAxisDate(date, span: span, calendar: calendar))
                            .font(.system(size: LimitsLayout.timelineDateSize, weight: .medium))
                            .foregroundStyle(color(.secondary))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: timeline.axis) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color(.hairline))
                AxisValueLabel {
                    if let points = value.as(Double.self) {
                        Text(LimitsCopy.timelineAxisLabel(points))
                            .font(.system(size: LimitsLayout.timelineAxisSize))
                            .foregroundStyle(color(.secondary))
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            hoverLayer(proxy, timeline: timeline)
        }
    }

    /// The pointer picks the bar under it; its tooltip sits beside the bar, on the side
    /// where it fits (`HistoryTooltipRules.leadingX`). A half hour with no bar shows none.
    private func hoverLayer(_ proxy: ChartProxy, timeline: LimitsTimeline) -> some View {
        GeometryReader { geometry in
            let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let time: Date? = proxy.value(atX: location.x - plot.minX)
                            hovered = time.flatMap { moment in
                                timeline.bars.first { $0.start <= moment && moment < $0.end }
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
                if let bar = hovered,
                   let left = proxy.position(forX: bar.start),
                   let right = proxy.position(forX: bar.end) {
                    HistoryTooltipView(
                        tooltip: LimitsRules.timelineTooltip(for: bar, in: timeline, now: Date(), calendar: calendar),
                        width: LimitsLayout.timelineTooltipWidth
                    )
                    .offset(
                        x: plot.minX + HistoryTooltipRules.leadingX(
                            anchorX: (left + right) / 2,
                            clearance: (right - left) / 2 + HistoryTooltipRules.gap,
                            width: LimitsLayout.timelineTooltipWidth,
                            plotWidth: plot.width
                        ),
                        y: plot.minY + HistoryLayout.tooltipTopInset
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// The series' dots and names, wrapping as the card narrows.
    private func legend(_ timeline: LimitsTimeline) -> some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: LimitsLayout.timelineLegendItemWidth),
                spacing: LimitsLayout.timelineLegendColumnSpacing,
                alignment: .leading
            )],
            alignment: .leading,
            spacing: LimitsLayout.timelineLegendRowSpacing
        ) {
            ForEach(timeline.series) { series in
                HStack(spacing: LimitsLayout.timelineLegendDotSpacing) {
                    Circle()
                        .fill(.om(series.token))
                        .frame(width: LimitsLayout.timelineLegendDotSize, height: LimitsLayout.timelineLegendDotSize)
                    Text(series.name)
                        .font(.system(size: LimitsLayout.timelineLegendSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(series.name)
            }
        }
    }

    private func color(_ token: OMColorToken) -> Color {
        OMPalette.rgba(token, scheme: colorScheme).color
    }
}
