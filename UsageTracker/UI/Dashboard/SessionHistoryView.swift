import SwiftUI
import Charts

/// Dashboard → History (liquid-glass spec § Screens, the History rows): the title and
/// its one sentence, a controls row, the selected provider's days and, for a provider
/// whose log names its chats, the chat list under them.
struct SessionHistoryView: View {
    /// Only for one question — is the selected provider pay-as-you-go — but that
    /// question decides the header's sentence, so it has to come from the live
    /// snapshot rather than from the dashboard's derived state.
    @ObservedObject var appState: AppState
    @ObservedObject var dashboard: DashboardState

    @AppStorage("historyChartMode") private var chartMode: HistoryChartMode = .cost

    /// Providers with no local cost log get their quota charted over the same range
    /// instead of an empty state. On a subscription the quota *is* the consumption,
    /// so this is the same story the cost chart tells, in the only unit available.
    private var showsQuota: Bool { !dashboard.costSource.hasBreakdown }

    /// Whether the selected provider's log identifies a chat at all.
    private var hasSessionLog: Bool {
        DashboardState.hasSessionLog(for: dashboard.selectedService)
    }

    /// `chartMode` as 3.0 reads it — see `HistoryRules.effectiveMode`.
    private var mode: HistoryChartMode {
        HistoryRules.effectiveMode(stored: chartMode)
    }

    /// The range on screen — see `HistoryRules.offeredRange`.
    private var range: TimeRange { HistoryRules.offeredRange(dashboard.range) }

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
            range: range,
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
        let started = cacheKey
        let records = dashboard.history
        let buckets = dashboard.quotaBuckets
        let span = range.seconds
        let built = await Task.detached(priority: .userInitiated) {
            QuotaHistoryCache.build(records: records, buckets: buckets, span: span)
        }.value
        // See `DerivedCacheGate`: a pass for the provider or range just left must not
        // land after the new one's.
        guard DerivedCacheGate.canPublish(
            started: started, current: cacheKey, cancelled: Task.isCancelled
        ) else { return }
        quota = built
    }

    private var data: [DailyPoint] {
        let daily = dashboard.cliBreakdown?.daily ?? []
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-range.seconds))
        return daily
            .filter { $0.day >= cutoff }
            .map {
                DailyPoint(
                    day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens,
                    turns: $0.turns, breakdown: $0.tokens
                )
            }
    }

    var body: some View {
        // Measured here, once, off the width the tab is given: the chat list's column
        // header and every one of its rows then draw to the same decision.
        GeometryReader { proxy in
            scrollBody(isWide: HistoryLayout.isWideList(detailWidth: proxy.size.width))
        }
    }

    private func scrollBody(isWide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HistoryLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: 0) {
                    DashboardHeader(
                        title: HistoryCopy.title,
                        subtitle: subtitle,
                        showsServicePicker: false
                    )
                    controls
                        .padding(.top, HistoryLayout.controlsTopPadding)
                        .padding(.leading, DashboardShellLayout.columnLeading)
                        .padding(.trailing, DashboardShellLayout.columnTrailing)
                }

                Group {
                    if showsQuota {
                        quotaContent
                    } else {
                        if data.isEmpty {
                            placeholder
                        } else if mode == .tokens {
                            tokensChart
                        } else {
                            chart
                        }
                        // The chat list sits under the chart in both units (spec
                        // § Screens, "History · Chart").
                        if hasSessionLog {
                            HistorySessionsCard(dashboard: dashboard, isWide: isWide)
                        }
                    }
                }
                .padding(.leading, DashboardShellLayout.columnLeading)
                .padding(.trailing, DashboardShellLayout.columnTrailing)

                Spacer(minLength: DashboardShellLayout.columnTrailing)
            }
        }
        .task(id: cacheKey) {
            await rebuildQuota()
        }
        // 5h is a range Agents offers and History does not: the page shows a day and
        // writes it back, so the two tabs agree on the range.
        .task(id: dashboard.range) {
            let offered = HistoryRules.offeredRange(dashboard.range)
            if offered != dashboard.range { dashboard.range = offered }
        }
    }

    /// The header's sentence — see `HistoryCopy.subtitle`. Whether the dollars are a
    /// bill comes from the live snapshot, the rule Overview and Insights use.
    private var subtitle: String {
        HistoryCopy.subtitle(
            showsQuota: showsQuota,
            providerName: dashboard.displayName(for: dashboard.selectedService),
            sourceName: dashboard.costSource.longName,
            isPayAsYouGo: appState.snapshot.services
                .first { $0.id == dashboard.selectedService }
                .map(CostCopy.isPayAsYouGo) ?? false
        )
    }

    /// The mockups' controls row under the title: the provider on the left, History's
    /// own switches on the right. It wraps before it clips, as the header does.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HistoryLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                Spacer(minLength: HistoryLayout.controlSpacing)
                pickers
            }
            VStack(alignment: .leading, spacing: HistoryLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                HStack(spacing: HistoryLayout.controlSpacing) { pickers }
            }
            VStack(alignment: .leading, spacing: HistoryLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                pickers
            }
        }
    }

    /// A provider with no cost log has one unit to chart: it gets the range and nothing
    /// to toggle.
    @ViewBuilder
    private var pickers: some View {
        if !showsQuota { modePicker }
        RangePicker(range: $dashboard.range, ranges: HistoryRules.ranges)
    }

    /// Bound through `mode`, not through `chartMode` directly: the capsule shows the
    /// segment whose id is selected, and `chartMode` can still hold 2.x's `.sessions`.
    private var modePicker: some View {
        OMSegmentedControl(
            items: HistoryRules.chartModes.map { OMSegmentItem(id: $0.rawValue, title: $0.displayName) },
            selection: Binding(
                get: { mode.rawValue },
                set: { chartMode = HistoryChartMode(rawValue: $0) ?? chartMode }
            ),
            alwaysShowsTitles: true,
            keyboardShortcuts: false,
            accessibilityLabel: HistoryCopy.modePickerLabel
        )
        .fixedSize()
    }

    // MARK: - Quota

    @ViewBuilder
    private var quotaContent: some View {
        if quota.series.isEmpty {
            noQuotaPlaceholder
        } else {
            quotaChart
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
    }

    /// The quota chart answers "how much did I use", not "what did it cost" — say
    /// which of the two this is, so the missing dollars don't read as a bug.
    private var costFootnote: some View {
        Text(dashboard.costSource.reason ?? "")
            .font(OMFont.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
    }

    private var barGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Tokens

    /// One bar per day, split by what the tokens were. `TokenCategory.allCases` is
    /// both the stacking order and the legend's order, and the scale below pins
    /// each label to its colour — left alone, Charts picks its own palette and the
    /// bar stops matching the Overview card.
    private var tokensChart: some View {
        Chart {
            ForEach(data) { point in
                ForEach(TokenCategory.allCases) { category in
                    BarMark(
                        x: .value("Day", point.day, unit: .day),
                        y: .value("Tokens", category.tokens(in: point.breakdown))
                    )
                    .foregroundStyle(by: .value("Type", category.label))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: TokenCategory.allCases.map(\.label),
            range: TokenCategory.allCases.map(\.color)
        )
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, data.count / 8))) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    // A million-token day is the norm; raw digits would be a wall.
                    if let tokens = value.as(Int.self) {
                        Text(TokenFormat.formatTokens(tokens))
                    } else if let tokens = value.as(Double.self) {
                        Text(TokenFormat.formatTokens(Int(tokens)))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(minHeight: 260)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No CLI usage recorded yet")
                .foregroundStyle(.secondary)
            Text("Run a `\(DashboardState.cliCommandName(for: dashboard.selectedService))` session to start collecting data")
                .font(OMFont.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// Which unit the history tab charts. Persisted (`@AppStorage`), so the tab
/// reopens on whichever question the user was last asking. Internal rather than
/// private: the raw values are a storage contract and are asserted in tests.
/// `sessions` is 2.x's third mode, kept so a stored value still decodes; 3.0 never
/// offers it (`HistoryRules.chartModes`).
enum HistoryChartMode: String, CaseIterable, Identifiable {
    case cost, tokens, sessions
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cost: return "Cost"
        case .tokens: return "Tokens"
        case .sessions: return "Sessions"
        }
    }
}

private struct DailyPoint: Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    let turns: Int
    /// The same day's tokens split by what they were. `tokens` stays the headline
    /// figure: for Grok the CLI's own total is authoritative and may differ from
    /// the sum of the parts.
    let breakdown: TokenBreakdown
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

    static let empty = QuotaHistoryCache(series: [])

    static func build(records: [HistoryRecord], buckets: [QuotaBucketInfo], span: TimeInterval) -> QuotaHistoryCache {
        let to = Date()
        let from = to.addingTimeInterval(-span)
        // Every window gets a line, core or not: a promotional pool is still quota the
        // user can watch drain.
        let series = buckets.compactMap { bucket -> QuotaSeries? in
            let points = QuotaAnalytics.series(records: records, bucketID: bucket.id, from: from, to: to)
            return points.isEmpty ? nil : QuotaSeries(bucket: bucket, points: points)
        }
        return QuotaHistoryCache(series: series)
    }
}
