import SwiftUI
import Charts

/// History → Chart (liquid-glass spec § Screens, "History · Chart"): cost or tokens per
/// day over the page's range, on a card whose header carries the range's total (Cost)
/// or the token legend (Tokens). What it says and how each bar looks come from
/// `HistoryRules` and `HistoryCopy`; colours from the 3.0 tokens, resolved for the
/// window's appearance because Charts takes a `Color`.
struct HistoryChartCard: View {
    /// The range's days with a row (`HistoryRules.days`).
    let days: [HistoryDay]
    let mode: HistoryChartMode
    let range: TimeRange
    /// One clock for the page: the bars, the total and today's bar agree.
    let now: Date
    /// What the empty state asks the user to run (`DashboardState.cliCommandName`).
    let command: String

    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current

    private var dayCount: Int {
        HistoryRules.dayCount(range: range, now: now, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HistoryLayout.chartCardSpacing) {
            header
            if days.isEmpty {
                placeholder
            } else {
                chart
                    .frame(height: HistoryLayout.chartHeight)
            }
        }
        .padding(HistoryLayout.chartCardPadding)
        .dashboardCard(padding: 0)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(HistoryCopy.chartTitle(mode: mode))
                .font(.system(size: HistoryLayout.cardTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
            Spacer(minLength: 12)
            if mode == .tokens {
                legend
            } else {
                Text(HistoryCopy.chartSummary(
                    HistoryRules.summary(days, range: range, now: now, calendar: calendar)
                ))
                .font(.system(size: HistoryLayout.cardCaptionSize))
                .foregroundStyle(.om(.secondary))
            }
        }
    }

    /// The four types in stacking order, which is also the order the bars stack in.
    private var legend: some View {
        HStack(spacing: HistoryLayout.legendSpacing) {
            ForEach(TokenCategory.allCases) { category in
                HStack(spacing: 7) {
                    Circle()
                        .fill(.om(category.token))
                        .frame(width: HistoryLayout.legendDotSize, height: HistoryLayout.legendDotSize)
                    Text(category.label)
                        .font(.system(size: HistoryLayout.rowSubtitleSize))
                        .foregroundStyle(.om(.secondary))
                }
                .help(category.help ?? category.label)
            }
        }
    }

    private var chart: some View {
        let dayCount = self.dayCount
        let labelled = HistoryRules.showsValueLabels(dayCount: dayCount)
        return Chart {
            ForEach(days) { day in
                let today = HistoryRules.isToday(day.day, now: now, calendar: calendar)
                if mode == .tokens {
                    ForEach(TokenCategory.allCases) { category in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Tokens", category.tokens(in: day.breakdown)),
                            width: .ratio(HistoryLayout.barWidthRatio)
                        )
                        .foregroundStyle(color(category.token))
                    }
                    if labelled {
                        // An invisible point at the top of the stack carries the day's figure.
                        PointMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value("Tokens", day.breakdown.total)
                        )
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 4) {
                            valueLabel(HistoryCopy.tokenBarLabel(day.tokens), today: today)
                        }
                    }
                } else {
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Cost", day.cost),
                        width: .ratio(HistoryLayout.barWidthRatio)
                    )
                    .foregroundStyle(color(.accent).opacity(HistoryRules.barOpacity(isToday: today)))
                    .cornerRadius(HistoryRules.barCornerRadius(dayCount: dayCount))
                    .annotation(position: .top, spacing: 4) {
                        if labelled {
                            valueLabel(HistoryCopy.costBarLabel(day.cost), today: today)
                        }
                    }
                }
            }
        }
        .chartXScale(domain: HistoryRules.xDomain(range: range, now: now, calendar: calendar))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: HistoryRules.axisStride(dayCount: dayCount))) { value in
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        let today = HistoryRules.isToday(date, now: now, calendar: calendar)
                        Text(HistoryCopy.axisDay(date, calendar: calendar))
                            .font(.system(size: HistoryLayout.barLabelSize, weight: today ? .semibold : .medium))
                            .foregroundStyle(color(today ? .text : .secondary))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(color(.hairline))
                AxisValueLabel {
                    if let label = yLabel(value) {
                        Text(label)
                            .font(.system(size: HistoryLayout.axisLabelSize))
                            .foregroundStyle(color(.secondary))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func yLabel(_ value: AxisValue) -> String? {
        guard let number = value.as(Double.self) ?? value.as(Int.self).map({ Double($0) }) else { return nil }
        return mode == .tokens ? HistoryCopy.tokenAxisLabel(number) : HistoryCopy.costAxisLabel(number)
    }

    private func valueLabel(_ text: String, today: Bool) -> some View {
        Text(text)
            .font(.system(size: HistoryLayout.barLabelSize, weight: today ? .semibold : .medium))
            .foregroundStyle(color(today ? .text : .secondary))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(.om(.muted))
            Text(HistoryCopy.emptyChartTitle)
                .foregroundStyle(.om(.secondary))
            Text(HistoryCopy.emptyChartHint(command: command))
                .font(OMFont.body)
                .foregroundStyle(.om(.secondary))
        }
        .frame(maxWidth: .infinity, minHeight: HistoryLayout.chartHeight)
    }

    private func color(_ token: OMColorToken) -> Color {
        OMPalette.rgba(token, scheme: colorScheme).color
    }
}
