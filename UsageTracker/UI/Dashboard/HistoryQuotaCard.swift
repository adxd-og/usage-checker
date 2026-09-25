import SwiftUI
import Charts

/// History for a provider with no local cost log (liquid-glass spec § Screens, "History
/// · quota-only provider"): one line per window on a fixed 0–100 % axis, the windows
/// named in a legend above it. On a subscription the quota *is* the consumption, so
/// this is the cost chart's story in the only unit available.
struct HistoryQuotaCard: View {
    let series: [HistoryQuotaSeries]
    /// The x extent the lines were built for (`HistoryRules.quotaChart`, cached by the
    /// page with them); the card computes none of its own.
    let domain: ClosedRange<Date>
    let range: TimeRange
    /// Whose quota the empty state says has not been recorded yet.
    let providerName: String

    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryLayout.quotaCardSpacing) {
            if series.isEmpty {
                placeholder
            } else {
                legend
                chart
                    .frame(height: HistoryLayout.quotaChartHeight)
            }
        }
        .padding(HistoryLayout.chartCardPadding)
        .dashboardCard(padding: 0)
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: HistoryLayout.quotaLegendItemWidth), spacing: 18, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(.om(HistoryRules.quotaSeriesToken(index: index)))
                        .frame(width: HistoryLayout.legendDotSize, height: HistoryLayout.legendDotSize)
                    Text(item.bucket.label)
                        .font(.system(size: HistoryLayout.rowSubtitleSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                }
            }
        }
    }

    private var chart: some View {
        let axisStride = HistoryRules.quotaAxisStride(range: range)
        return Chart {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                ForEach(item.points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Used", point.percent),
                        series: .value("Window", item.id)
                    )
                    .foregroundStyle(color(HistoryRules.quotaSeriesToken(index: index)))
                    .lineStyle(StrokeStyle(lineWidth: HistoryLayout.quotaLineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: HistoryRules.quotaAxisValues) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color(.hairline))
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(HistoryCopy.percent(percent))
                            .font(.system(size: HistoryLayout.axisLabelSize))
                            .foregroundStyle(color(.secondary))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: axisStride.component, count: axisStride.count)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(HistoryCopy.quotaAxisLabel(date, range: range, calendar: calendar))
                            .font(.system(size: HistoryLayout.barLabelSize))
                            .foregroundStyle(color(.secondary))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    /// Quota history only starts when the app first polls this provider successfully,
    /// so a fresh provider has an honest reason for an empty chart.
    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.largeTitle)
                .foregroundStyle(.om(.muted))
            Text(HistoryCopy.noQuotaTitle(provider: providerName))
                .foregroundStyle(.om(.secondary))
            Text(HistoryCopy.noQuotaHint)
                .font(OMFont.body)
                .foregroundStyle(.om(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: HistoryLayout.chartHeight)
    }

    private func color(_ token: OMColorToken) -> Color {
        OMPalette.rgba(token, scheme: colorScheme).color
    }
}
