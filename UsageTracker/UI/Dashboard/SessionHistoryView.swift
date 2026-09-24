import SwiftUI
import Charts

struct SessionHistoryView: View {
    /// Only for one question — is the selected provider pay-as-you-go — but that
    /// question decides a line of copy under the chart, so it has to come from the
    /// live snapshot rather than from the dashboard's derived state.
    @ObservedObject var appState: AppState
    @ObservedObject var dashboard: DashboardState

    @AppStorage("historyChartMode") private var chartMode: HistoryChartMode = .cost

    /// Which chats are open. Per row and not persisted: an expanded chat is a decision
    /// about *this* chat, and a tab that reopens with four rows unfolded is noise.
    @State private var expandedSessionIDs: Set<String> = []
    /// Whether "Show all N" has been pressed. Reset whenever the provider or the range
    /// changes — the number in the button would otherwise be about a different list.
    @State private var showsAllSessions = false
    /// The full list's order. Persisted like the mode: it is a question the user asks
    /// repeatedly ("what has this cost me?"), not a per-visit choice.
    @AppStorage("historySessionSort") private var sessionSort: SessionListRule.Sort = .recent

    /// Providers with no local cost log get their quota charted over the same range
    /// instead of an empty state. On a subscription the quota *is* the consumption,
    /// so this is the same story the cost chart tells, in the only unit available.
    private var showsQuota: Bool { !dashboard.costSource.hasBreakdown }

    /// Whether the selected provider's log identifies a chat at all.
    private var hasSessionLog: Bool {
        DashboardState.hasSessionLog(for: dashboard.selectedService)
    }

    /// `chartMode` corrected for the provider on screen — see `effectiveMode`.
    private var mode: HistoryChartMode {
        Self.effectiveMode(stored: chartMode, hasSessionLog: hasSessionLog)
    }

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
        let started = cacheKey
        let records = dashboard.history
        let buckets = dashboard.quotaBuckets
        let span = dashboard.range.seconds
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
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-dashboard.range.seconds))
        return daily
            .filter { $0.day >= cutoff }
            .map {
                DailyPoint(
                    day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens,
                    turns: $0.turns, breakdown: $0.tokens
                )
            }
    }

    /// The gutters `sessionList` pads itself with, taken off the tab's width before the
    /// list decides how to draw.
    private static let listGutters: CGFloat = 48

    var body: some View {
        // Measured here, once, off the width the tab is given rather than off the width
        // a row's content grew to: the Sessions list, its header and every one of its
        // rows then draw to the same decision.
        GeometryReader { proxy in
            let isWide = SessionListRule.isWide(
                availableWidth: proxy.size.width - Self.listGutters
            )
            scrollBody(isWide: isWide)
        }
    }

    private func scrollBody(isWide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // The caption belongs to the header, so it sits under the header's own
                // bottom padding rather than a whole section gap below it.
                VStack(alignment: .leading, spacing: 0) {
                    DashboardHeader(
                        title: showsQuota ? "Quota history" : "Session history",
                        subtitle: subtitle.line,
                        // A provider with no cost log has one unit to chart, so it is
                        // shown a range control and nothing to toggle.
                        trailing: AnyView(
                            HStack(spacing: 12) {
                                if !showsQuota { modePicker }
                                RangePicker(range: $dashboard.range)
                            }
                        )
                    )
                    if let caption = subtitle.caption {
                        Text(caption)
                            .font(OMFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }
                }

                if showsQuota {
                    quotaContent
                } else if mode == .sessions {
                    sessionsContent(isWide: isWide)
                } else if data.isEmpty {
                    placeholder
                } else if mode == .tokens {
                    tokensChart
                    Divider().padding(.horizontal, 24)
                    tokensTable
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
        // Provider or range changed: the button's "Show all 34" and any open row are
        // about a list that no longer exists.
        .task(id: SessionScope(service: dashboard.selectedService, range: dashboard.range)) {
            showsAllSessions = false
            expandedSessionIDs = []
        }
        .task(id: sessionsKey) {
            guard mode == .sessions else { return }
            await dashboard.refreshSessions()
        }
    }

    /// Bound through `mode`, not through `chartMode` directly: a segmented control whose
    /// selection is not among its own tags shows nothing selected, and `chartMode` can
    /// hold `.sessions` under a provider that is not offered it.
    private var modePicker: some View {
        let offered = Self.modes(hasSessionLog: hasSessionLog)
        return Picker("", selection: Binding(get: { mode }, set: { chartMode = $0 })) {
            ForEach(offered) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: offered.count > 2 ? 210 : 140)
    }

    private var subtitle: (line: String, caption: String?) {
        Self.subtitle(
            showsQuota: showsQuota,
            providerName: dashboard.displayName(for: dashboard.selectedService),
            longName: dashboard.costSource.longName,
            mode: mode,
            isPayAsYouGo: appState.snapshot.services
                .first { $0.id == dashboard.selectedService }
                .map(CostCopy.isPayAsYouGo) ?? false,
            range: dashboard.range
        )
    }

    /// The header line under "Session history", and the caption drawn under the header
    /// on a line of its own. Pure so both rules are testable: the line names the unit on
    /// the chart (there are no dollars on the Tokens chart to call a daily cost), and only
    /// the cost chart explains what its dollars are.
    ///
    /// The caption is separate because it is a sentence of its own. Riding on the line,
    /// it made the Cost header 666 pt wide, wider than the detail column at the
    /// dashboard's 820 pt minimum, and it was the part that got cut off.
    nonisolated static func subtitle(
        showsQuota: Bool,
        providerName: String,
        longName: String?,
        mode: HistoryChartMode,
        isPayAsYouGo: Bool,
        range: TimeRange = .sevenDays
    ) -> (line: String, caption: String?) {
        if showsQuota { return ("How full \(providerName)'s usage windows ran", nil) }
        if mode == .sessions {
            return (sessionsSubtitle(source: longName, range: range, isPayAsYouGo: isPayAsYouGo), nil)
        }
        let line = costSubtitle(mode: mode, source: longName)
        guard mode == .cost else { return (line, nil) }
        return (line, CostCopy.apiEquivalentCaption(isPayAsYouGo: isPayAsYouGo))
    }

    /// "Daily cost from …" or "Daily tokens by type from …".
    nonisolated static func costSubtitle(mode: HistoryChartMode, source: String?) -> String {
        let unit = mode == .tokens ? "Daily tokens by type" : "Daily cost"
        return source.map { "\(unit) from \($0)" } ?? unit
    }

    /// The Sessions header line. The dollars are qualified inside the sentence rather
    /// than by the long `CostCopy` caption the Cost mode draws under the header: this
    /// subtitle already names what the dollars are, and a second sentence saying it
    /// again would be noise.
    ///
    /// The five-hour range is the one control that does not mean what it says — the
    /// aggregators widen anything shorter than a day to the local day it falls in — so
    /// this is where that is said out loud.
    nonisolated static func sessionsSubtitle(
        source: String?, range: TimeRange, isPayAsYouGo: Bool
    ) -> String {
        let dollars = isPayAsYouGo ? "cost" : "API-equivalent cost"
        let head = source.map { "Chats from \($0), tokens and \(dollars)" }
            ?? "Chats, tokens and \(dollars)"
        guard range == .fiveHours else { return head }
        return head + " · today, not the last 5 hours"
    }

    /// The mode actually in force. `historyChartMode` is one persisted value across
    /// every provider, and Grok writes a per-turn cost log but nothing that names a
    /// chat — landing on its tab with Sessions remembered must show the cost chart.
    /// The stored choice is deliberately left alone, so switching back to Claude
    /// restores it.
    nonisolated static func effectiveMode(
        stored: HistoryChartMode, hasSessionLog: Bool
    ) -> HistoryChartMode {
        stored == .sessions && !hasSessionLog ? .cost : stored
    }

    /// The segments the picker offers for this provider.
    nonisolated static func modes(hasSessionLog: Bool) -> [HistoryChartMode] {
        HistoryChartMode.allCases.filter { $0 != .sessions || hasSessionLog }
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
        .padding(.horizontal, 24)
    }

    /// The chart's numbers, per day. Cache columns are secondary: they are usually
    /// the biggest figures on the row and the least actionable.
    private var tokensTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Day").font(OMFont.body).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                Spacer()
                // The column is the uncached input; "In" is all the width there is.
                Text("In").font(OMFont.body).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                    .help(TokenCategory.input.help ?? TokenCategory.input.label)
                Text("Out").font(OMFont.body).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                Text("Cache read").font(OMFont.body).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                Text("Cache write").font(OMFont.body).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                Text("Cost").font(OMFont.body).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            .padding(.bottom, 6)
            ForEach(data.reversed()) { p in
                HStack {
                    Text(p.day.formatted(date: .abbreviated, time: .omitted)).font(OMFont.body)
                        .frame(width: 120, alignment: .leading)
                    Spacer()
                    Text(TokenFormat.formatTokens(p.breakdown.input))
                        .font(OMFont.numeral).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(TokenFormat.formatTokens(p.breakdown.output))
                        .font(OMFont.numeral).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(TokenFormat.formatTokens(p.breakdown.cacheRead))
                        .font(OMFont.numeral).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(TokenFormat.formatTokens(p.breakdown.cacheWrite))
                        .font(OMFont.numeral).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(String(format: "$%.2f", p.cost))
                        .font(OMFont.numeral).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if p.id != data.first?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
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
                    Text(TokenFormat.formatTokens(p.tokens)).font(OMFont.numeral).monospacedDigit().frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
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
            Text("Run a `\(DashboardState.cliCommandName(for: dashboard.selectedService))` session to start collecting data")
                .font(OMFont.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Sessions

    /// Everything the Sessions list is keyed against. `updatedAt` is the aggregator's
    /// own ingest stamp, so a poll that changed nothing re-triggers nothing.
    private struct SessionsKey: Hashable {
        let service: String
        let range: TimeRange
        let isSessions: Bool
        let updatedAt: Date
    }

    /// Just the two things that invalidate the list's *controls*, as opposed to its
    /// contents.
    private struct SessionScope: Hashable {
        let service: String
        let range: TimeRange
    }

    private var sessionsKey: SessionsKey {
        SessionsKey(
            service: dashboard.selectedService,
            range: dashboard.range,
            isSessions: mode == .sessions,
            updatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast
        )
    }

    private var sessionRows: [SessionRow] {
        showsAllSessions
            ? SessionListRule.sorted(dashboard.sessions, by: sessionSort)
            : SessionListRule.pick(sessions: dashboard.sessions)
    }

    /// The chart above the list is the cost chart, unchanged: the list answers "which
    /// chat", and the bars are the context that makes the answer mean something.
    @ViewBuilder
    private func sessionsContent(isWide: Bool) -> some View {
        if !data.isEmpty {
            chart
            Divider().padding(.horizontal, 24)
        }
        if dashboard.sessions.isEmpty {
            sessionsPlaceholder
        } else {
            sessionList(isWide: isWide)
        }
    }

    private func sessionList(isWide: Bool) -> some View {
        let rows = sessionRows
        return VStack(alignment: .leading, spacing: 0) {
            sessionListControls(shown: rows.count)
            // The empty list has its own sentence; a header over nothing is furniture.
            if !rows.isEmpty { sessionColumnHeader(isWide: isWide) }
            ForEach(rows) { row in
                SessionRowView(
                    row: row,
                    now: Date(),
                    isWide: isWide,
                    isExpanded: expandedSessionIDs.contains(row.id),
                    toggle: { toggleSession(row.id) }
                )
                if row.id != rows.last?.id { Divider().opacity(0.3) }
            }
        }
        .padding(.horizontal, 24)
    }

    /// Names the figures on a chat row, the way the by-day tables above name theirs.
    /// The widths are `SessionRowView.wideSummary`'s, so a title sits over its own
    /// column. Which of the two it draws is not its own decision — the list measured
    /// that once, for the header and every row alike.
    private func sessionColumnHeader(isWide: Bool) -> some View {
        Group {
            if isWide {
                HStack(spacing: OMSpacing.s) {
                    Color.clear.frame(width: 16, height: 1)  // the row's chevron
                    Text(sessionColumnTitle(0)).frame(minWidth: 160, alignment: .leading)
                    Spacer(minLength: OMSpacing.s)
                    Text(sessionColumnTitle(1)).frame(width: 104, alignment: .trailing)
                    Text(sessionColumnTitle(2)).frame(width: 64, alignment: .trailing)
                    Text(sessionColumnTitle(3)).frame(width: 84, alignment: .trailing)
                    Text(sessionColumnTitle(4)).frame(width: 76, alignment: .trailing)
                }
            } else {
                HStack(spacing: OMSpacing.s) {
                    Color.clear.frame(width: 16, height: 1)
                    Text(sessionColumnTitle(0))
                    Spacer(minLength: OMSpacing.s)
                    Text(sessionColumnTitle(4))
                }
            }
        }
        .font(OMFont.body)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func sessionColumnTitle(_ index: Int) -> String {
        let titles = SessionCopy.listColumns
        return titles.indices.contains(index) ? titles[index] : ""
    }

    private func sessionListControls(shown: Int) -> some View {
        let total = dashboard.sessions.count
        return HStack(spacing: OMSpacing.m) {
            Text(SessionCopy.listHeader(shown: shown, total: total))
                .font(OMFont.body)
                .foregroundStyle(.secondary)
            Spacer()
            if showsAllSessions {
                Picker("", selection: $sessionSort) {
                    ForEach(SessionListRule.Sort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            if showsAllSessions || SessionListRule.canShowAll(shown: shown, total: total) {
                Button(SessionCopy.showAll(count: total, expanded: showsAllSessions)) {
                    showsAllSessions.toggle()
                }
                .buttonStyle(.link)
            }
        }
        .padding(.bottom, OMSpacing.s)
    }

    private func toggleSession(_ id: String) {
        if expandedSessionIDs.contains(id) {
            expandedSessionIDs.remove(id)
        } else {
            expandedSessionIDs.insert(id)
        }
    }

    private var sessionsPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(SessionCopy.emptyTitle)
                .foregroundStyle(.secondary)
            if let hint = SessionCopy.emptyHint(providerID: dashboard.selectedService) {
                Text(hint)
                    .font(OMFont.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// Which unit the history tab charts. Persisted (`@AppStorage`), so the tab
/// reopens on whichever question the user was last asking. Internal rather than
/// private: the raw values are a storage contract and are asserted in tests.
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

/// One chat in History's Sessions list, collapsed to a line and expanded to the three
/// sections of § 4. Every string comes from `SessionCopy`; this view decides layout and
/// nothing else.
///
/// The dashboard's minimum is a 820 pt window with a 160 pt sidebar, which leaves about
/// 611 pt here — more than the 560 the wide row asks for (`SessionListRule.isWide`), so
/// that window draws five columns. `isWide` arrives from the list rather than being
/// measured here: a row that decides for itself disagrees with the header above it and
/// with the row below it, because what it measures is its own chat title.
///
/// The expanded half is built into `@State` by `SessionDetail.build`, never computed in
/// `body`: one chat on this Mac launched 1,235 sub-agents, and the eight the table draws
/// have to be chosen off the main actor and once, not on every re-render of the list.
private struct SessionRowView: View {
    let row: SessionRow
    let now: Date
    /// The list's one layout decision — see `SessionListRule.minimumWideWidth`.
    let isWide: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    private var session: SessionSummary { row.session }

    /// The expanded sections, built once per (chat content, cap state) rather than per
    /// re-render: `session.agents` reaches 1,235 entries on this Mac, and sorting and
    /// formatting that inside `body` would run on every poll and every hover. What
    /// "chat content" means is `SessionListRule.detailKey`.
    @State private var detail = SessionDetail.empty
    @State private var showsAllAgents = false
    @State private var showsAllDays = false
    @State private var showsAllModels = false

    private var detailKey: SessionListRule.DetailKey {
        SessionListRule.detailKey(
            session: session, expanded: isExpanded,
            allAgents: showsAllAgents, allDays: showsAllDays, allModels: showsAllModels
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            if isWide { wideSummary } else { narrowSummary }
            if isExpanded { detailBlock }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionCopy.rowTitle(session))
        .accessibilityHint(isExpanded ? "Hides this chat's breakdown" : "Shows this chat's breakdown")
        .task(id: detailKey) {
            guard isExpanded else {
                detail = .empty
                // Collapsing forgets the caps too: reopening a chat should start from
                // the eight rows, not from a thousand somebody expanded last week.
                showsAllAgents = false
                showsAllDays = false
                showsAllModels = false
                return
            }
            let started = detailKey
            let session = self.session
            let allAgents = showsAllAgents
            let allDays = showsAllDays
            let allModels = showsAllModels
            let built = await Task.detached(priority: .userInitiated) {
                SessionDetail.build(
                    session: session, allAgents: allAgents, allDays: allDays, allModels: allModels
                )
            }.value
            // See `DerivedCacheGate`. A collapse, a lifted cap or a newer summary of the
            // chat restarts this task and cancels this pass, but the await does not stop
            // for that. `row` and `isExpanded` are `let`s this pass captured, so for those
            // the cancellation half of the gate is what drops a stale build; the three
            // caps are `@State` and read as they are now.
            guard DerivedCacheGate.canPublish(
                started: started, current: detailKey, cancelled: Task.isCancelled
            ) else { return }
            detail = built
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .frame(width: 16, height: 16)
    }

    /// The chat's name and its chips. The name is the one thing on the row that has no
    /// length: it is a prompt's first line, and it yields — `fixedSize` keeps the chips
    /// whole and the name gives up the space instead. It truncates at the tail, not the
    /// middle: a title that keeps its last twenty characters spends them on the end of a
    /// system prompt, and what tells two chats apart is how they open.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OMSpacing.xs) {
                Text(SessionCopy.rowTitle(session))
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                if row.isTop {
                    OMChip(text: SessionCopy.topSpendChip, tint: .orange).fixedSize()
                }
                if let origin = SessionCopy.originChip(session.origin) {
                    OMChip(text: origin, tint: .secondary).fixedSize()
                }
            }
            Text(SessionCopy.projectName(providerID: session.providerID, projectSlug: session.projectSlug))
                .font(OMFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var lastActiveText: String {
        SessionCopy.lastActive(session.lastAt, now: now)
    }

    /// The four numeric columns keep their widths and their priority; the title takes
    /// what is left and truncates. A row is read down its columns, so a long chat name
    /// must never be the reason a figure moves or gets clipped.
    private var wideSummary: some View {
        HStack(spacing: OMSpacing.s) {
            chevron
            titleBlock
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            Spacer(minLength: OMSpacing.s)
            Text(lastActiveText)
                .font(OMFont.body).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
                .layoutPriority(1)
            Text("\(session.turns)")
                .font(OMFont.numeral).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .layoutPriority(1)
            Text(TokenFormat.formatTokens(session.tokens.total))
                .font(OMFont.numeral).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
                .layoutPriority(1)
            Text(SessionCopy.cost(session.tokens.cost?.total))
                .font(OMFont.numeral).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
                .layoutPriority(1)
        }
    }

    /// The same five figures with the last three folded onto a caption line, for a
    /// window too narrow to hold five columns. The cost is rigid here for the reason the
    /// columns are rigid in the wide row: it is the figure the row exists to show, and
    /// the title yields to it rather than clipping it.
    private var narrowSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OMSpacing.s) {
                chevron
                titleBlock.layoutPriority(0)
                Spacer(minLength: OMSpacing.s)
                Text(SessionCopy.cost(session.tokens.cost?.total))
                    .font(OMFont.numeral).monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
            }
            Text([
                lastActiveText,
                SessionCopy.turns(session.turns),
                "\(TokenFormat.formatTokens(session.tokens.total)) tokens",
            ].joined(separator: " · "))
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 16 + OMSpacing.s)
        }
    }

    @ViewBuilder
    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: OMSpacing.s) {
            if !detail.split.isEmpty {
                Text(detail.split)
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.modelRows.isEmpty { modelTable }
            if !detail.agentRows.isEmpty { agentTable }
            if !detail.dayRows.isEmpty { dayTable }
        }
        .padding(.leading, 16 + OMSpacing.s)
        .padding(.top, OMSpacing.xs)
    }

    /// Which models the chat ran on, most expensive first. The header row is the one
    /// the by-day tables in this tab carry, at this table's own widths; the effort sits
    /// beside the model name as a secondary label, so a chat whose log named none draws
    /// no empty column.
    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            OMSectionHeader(title: SessionCopy.byModelTitle)
            // The header names four columns, so it is drawn only where four columns are
            // drawn — the same one decision the chat rows above obey.
            if isWide { modelColumnHeader }
            ForEach(detail.modelRows) { columns in
                modelRow(columns)
            }
            if detail.hiddenModels > 0 || showsAllModels {
                Button(SessionCopy.showAllModels(count: detail.totalModels, expanded: showsAllModels)) {
                    showsAllModels.toggle()
                }
                .buttonStyle(.link)
                .font(OMFont.caption)
                .padding(.top, 2)
            }
        }
    }

    private var modelColumnHeader: some View {
        HStack(spacing: OMSpacing.s) {
            Text(modelColumnTitle(0)).frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: OMSpacing.xs)
            Text(modelColumnTitle(1)).frame(width: 48, alignment: .trailing)
            Text(modelColumnTitle(2)).frame(width: 76, alignment: .trailing)
            Text(modelColumnTitle(3)).frame(width: 72, alignment: .trailing)
        }
        .font(OMFont.body)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private func modelColumnTitle(_ index: Int) -> String {
        let titles = SessionCopy.modelColumnTitles
        return titles.indices.contains(index) ? titles[index] : ""
    }

    private func modelRow(_ columns: SessionModelColumns) -> some View {
        Group {
            if isWide {
                HStack(spacing: OMSpacing.s) {
                    modelName(columns).frame(minWidth: 120, alignment: .leading)
                    Spacer(minLength: OMSpacing.xs)
                    Text(columns.turns).font(OMFont.body).monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                    Text(columns.tokens).font(OMFont.body).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Text(columns.cost).font(OMFont.body).monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        modelName(columns)
                        Spacer()
                        Text(columns.cost).font(OMFont.body).monospacedDigit()
                    }
                    Text("\(columns.turns) turns · \(columns.tokens)")
                        .font(OMFont.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func modelName(_ columns: SessionModelColumns) -> some View {
        HStack(spacing: 4) {
            Text(columns.model).font(OMFont.body).lineLimit(1)
            if let effort = columns.effort {
                Text(effort).font(OMFont.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    /// The header counts every sub-agent; the table draws the eight most expensive plus
    /// the Main thread row, because one chat here launched 1,235 of them.
    private var agentTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            OMSectionHeader(title: detail.agentsTitle)
            ForEach(detail.agentRows) { columns in
                columnsRow(columns, strong: columns.id == "main")
            }
            if detail.hiddenAgents > 0 || showsAllAgents {
                Button(SessionCopy.showAllAgents(count: detail.totalAgents, expanded: showsAllAgents)) {
                    showsAllAgents.toggle()
                }
                .buttonStyle(.link)
                .font(OMFont.caption)
                .padding(.top, 2)
            }
        }
    }

    private func columnsRow(_ columns: SessionColumns, strong: Bool) -> some View {
        Group {
            if isWide {
                HStack(spacing: OMSpacing.s) {
                    Text(columns.name)
                        .font(strong ? OMFont.bodyStrong : OMFont.body)
                        .lineLimit(1)
                        .frame(minWidth: 120, alignment: .leading)
                    Spacer(minLength: OMSpacing.xs)
                    Text(columns.model).font(OMFont.body).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 96, alignment: .trailing)
                    Text(columns.effort).font(OMFont.body).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 64, alignment: .trailing)
                    Text(columns.turns).font(OMFont.body).monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                    Text(columns.tokens).font(OMFont.body).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Text(columns.cost).font(OMFont.body).monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(columns.name).font(strong ? OMFont.bodyStrong : OMFont.body).lineLimit(1)
                        Spacer()
                        Text(columns.cost).font(OMFont.body).monospacedDigit()
                    }
                    Text([columns.model, columns.effort, "\(columns.turns) turns", columns.tokens]
                        .joined(separator: " · "))
                        .font(OMFont.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var dayTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            OMSectionHeader(title: SessionCopy.byDayTitle)
            ForEach(detail.dayRows) { columns in
                HStack(spacing: OMSpacing.s) {
                    Text(columns.day).font(OMFont.body)
                        .frame(minWidth: 96, alignment: .leading)
                    Spacer(minLength: OMSpacing.xs)
                    Text(columns.turns).font(OMFont.body).monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                    Text(columns.tokens).font(OMFont.body).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                    Text(columns.cost).font(OMFont.body).monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
            if detail.hiddenDays > 0 || showsAllDays {
                Button(SessionCopy.showAllDays(count: detail.totalDays, expanded: showsAllDays)) {
                    showsAllDays.toggle()
                }
                .buttonStyle(.link)
                .font(OMFont.caption)
                .padding(.top, 2)
            }
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
