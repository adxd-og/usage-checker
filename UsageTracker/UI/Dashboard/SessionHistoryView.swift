import SwiftUI
import Charts

struct SessionHistoryView: View {
    @ObservedObject var dashboard: DashboardState

    /// Providers with no local cost log get their quota charted over the same range
    /// instead of an empty state. On a subscription the quota *is* the consumption,
    /// so this is the same story the cost chart tells, in the only unit available.
    private var showsQuota: Bool { !dashboard.costSource.hasBreakdown }

    // Built off the main actor: a 90-day range is six figures' worth of history
    // records and every one of them is touched per bucket (same pattern as
    // ActivityGridView's GridCache).
    @State private var quota = QuotaHistoryCache.empty

    private struct CacheKey: Hashable {
        let service: String
        let range: TimeRange
        let historyCount: Int
        let lastHistoryAt: Date
        let bucketIDs: [String]
    }

    private var cacheKey: CacheKey {
        CacheKey(
            service: dashboard.selectedService,
            range: dashboard.range,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            bucketIDs: dashboard.quotaBuckets.map(\.id)
        )
    }

    @MainActor
    private func rebuildQuota() async {
        guard showsQuota else {
            quota = .empty
            return
        }
        let records = dashboard.history
        let buckets = dashboard.quotaBuckets
        let span = dashboard.range.seconds
        quota = await Task.detached(priority: .userInitiated) {
            QuotaHistoryCache.build(records: records, buckets: buckets, span: span)
        }.value
    }

    private var data: [DailyPoint] {
        let daily = dashboard.cliBreakdown?.daily ?? []
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-dashboard.range.seconds))
        return daily
            .filter { $0.day >= cutoff }
            .map { DailyPoint(day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens, turns: $0.turns) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: showsQuota ? "Quota history" : "Session history",
                    subtitle: subtitle,
                    trailing: AnyView(RangePicker(range: $dashboard.range))
                )

                if showsQuota {
                    quotaContent
                } else if data.isEmpty {
                    placeholder
                } else {
                    chart
                    Divider().padding(.horizontal, 24)
                    table
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: cacheKey) {
            await rebuildQuota()
        }
    }

    private var subtitle: String {
        if showsQuota {
            return "How full \(dashboard.displayName(for: dashboard.selectedService))'s usage windows ran"
        }
        return dashboard.costSource.longName.map { "Daily cost from \($0)" } ?? "Daily cost"
    }

    // MARK: - Quota

    @ViewBuilder
    private var quotaContent: some View {
        if quota.series.isEmpty {
            noQuotaPlaceholder
        } else {
            quotaChart
            Divider().padding(.horizontal, 24)
            peakTable
            costFootnote
        }
    }

    /// One line per window, all on a fixed 0–100% axis. The scale is deliberately
    /// absolute rather than fitted to the data: half of the point is seeing how much
    /// headroom was left, which a rescaled axis hides.
    private var quotaChart: some View {
        Chart {
            ForEach(quota.series) { series in
                ForEach(series.points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Used", point.percent)
                    )
                    .foregroundStyle(by: .value("Window", series.bucket.label))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(minHeight: 260)
        .padding(.horizontal, 24)
    }

    private var peakTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Spacer()
                Text("Window").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .trailing)
                Text("Peak").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(quota.peaks.reversed()) { peak in
                HStack {
                    Text(peak.day.formatted(date: .abbreviated, time: .omitted)).font(OMFont.body)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text(quota.label(for: peak.peakBucketID)).font(OMFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 160, alignment: .trailing)
                    Text(String(format: "%.0f%%", peak.peak))
                        .font(OMFont.numeral)
                        .monospacedDigit()
                        .foregroundStyle(usageStatusColor(peak.peak))
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if peak.id != quota.peaks.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }

    /// The quota chart answers "how much did I use", not "what did it cost" — say
    /// which of the two this is, so the missing dollars don't read as a bug.
    private var costFootnote: some View {
        Text(dashboard.costSource.reason ?? "")
            .font(OMFont.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
    }

    private var noQuotaPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No quota recorded yet for \(dashboard.displayName(for: dashboard.selectedService))")
                .foregroundStyle(.secondary)
            Text("Windows are recorded on every successful poll — this fills in as the app runs.")
                .font(OMFont.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Cost

    private var chart: some View {
        Chart(data) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Cost ($)", point.cost)
            )
            .foregroundStyle(barGradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, data.count / 8))) { mark in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .frame(minHeight: 260)
        .padding(.horizontal, 24)
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(OMFont.body).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                Spacer()
                Text("Turns").font(OMFont.body).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                Text("Tokens").font(OMFont.body).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
                Text("Cost").font(OMFont.body).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(data.reversed()) { p in
                HStack {
                    Text(p.day.formatted(date: .abbreviated, time: .omitted)).font(OMFont.body)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text("\(p.turns)").font(OMFont.numeral).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text(formatTokens(p.tokens)).font(OMFont.numeral).monospacedDigit().frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", p.cost)).font(OMFont.numeral).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if p.id != data.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No CLI usage recorded yet")
                .foregroundStyle(.secondary)
            Text("Run a `claude` session to start collecting data")
                .font(OMFont.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct DailyPoint: Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    let turns: Int
    var id: Date { day }
}

// MARK: - Quota cache (computed off the main thread, then cached in @State)

private struct QuotaSeries: Identifiable, Sendable {
    let bucket: QuotaBucketInfo
    let points: [QuotaPoint]
    var id: String { bucket.id }
}

private struct QuotaHistoryCache: Sendable {
    let series: [QuotaSeries]
    let peaks: [DailyPeak]
    private let labels: [String: String]

    static let empty = QuotaHistoryCache(series: [], peaks: [], labels: [:])

    func label(for bucketID: String) -> String {
        labels[bucketID] ?? QuotaAnalytics.prettifiedLabel(for: bucketID)
    }

    static func build(records: [HistoryRecord], buckets: [QuotaBucketInfo], span: TimeInterval) -> QuotaHistoryCache {
        let to = Date()
        let from = to.addingTimeInterval(-span)
        // Every window gets a line, core or not: a promotional pool is still quota the
        // user can watch drain. Only the daily peaks below are restricted to the core
        // ones, because a peak has to mean one thing to be worth a column.
        let series = buckets.compactMap { bucket -> QuotaSeries? in
            let points = QuotaAnalytics.series(records: records, bucketID: bucket.id, from: from, to: to)
            return points.isEmpty ? nil : QuotaSeries(bucket: bucket, points: points)
        }
        let peaks = QuotaAnalytics.dailyPeaks(
            records: records.filter { $0.timestamp >= from },
            bucketIDs: buckets.filter(\.isCore).map(\.id)
        )
        return QuotaHistoryCache(
            series: series,
            peaks: peaks,
            labels: Dictionary(buckets.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
