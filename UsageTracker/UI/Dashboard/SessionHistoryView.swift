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
            .map {
                DailyPoint(
                    day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens,
                    turns: $0.turns, breakdown: $0.tokens
                )
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: showsQuota ? "Quota history" : "Session history",
                    subtitle: subtitle,
                    // A provider with no cost log has one unit to chart, so it is
                    // shown a range control and nothing to toggle.
                    trailing: AnyView(
                        HStack(spacing: 12) {
                            if !showsQuota { modePicker }
                            RangePicker(range: $dashboard.range)
                        }
                    )
                )

                if showsQuota {
                    quotaContent
                } else if mode == .sessions {
                    sessionsContent
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

    private var subtitle: String {
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

    /// The header line under "Session history". Pure so both rules are testable: the
    /// line names the unit on the chart (there are no dollars on the Tokens chart to
    /// call a daily cost), and only the cost chart explains what its dollars are.
    nonisolated static func subtitle(
        showsQuota: Bool,
        providerName: String,
        longName: String?,
        mode: HistoryChartMode,
        isPayAsYouGo: Bool,
        range: TimeRange = .sevenDays
    ) -> String {
        if showsQuota { return "How full \(providerName)'s usage windows ran" }
        if mode == .sessions {
            return sessionsSubtitle(source: longName, range: range, isPayAsYouGo: isPayAsYouGo)
        }
        let base = costSubtitle(mode: mode, source: longName)
        guard mode == .cost,
              let caption = CostCopy.apiEquivalentCaption(isPayAsYouGo: isPayAsYouGo)
        else { return base }
        return "\(base) · \(caption)"
    }

    /// "Daily cost from …" or "Daily tokens by type from …".
    nonisolated static func costSubtitle(mode: HistoryChartMode, source: String?) -> String {
        let unit = mode == .tokens ? "Daily tokens by type" : "Daily cost"
        return source.map { "\(unit) from \($0)" } ?? unit
    }

    /// The Sessions header line. The dollars are qualified inside the sentence rather
    /// than by the long `CostCopy` caption the Cost mode appends: this subtitle already
    /// lists three things, and a fourth clause pushes the header into its stacked
    /// layout at any ordinary window width.
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
    private var sessionsContent: some View {
        if !data.isEmpty {
            chart
            Divider().padding(.horizontal, 24)
        }
        if dashboard.sessions.isEmpty {
            sessionsPlaceholder
        } else {
            sessionList
        }
    }

    private var sessionList: some View {
        let rows = sessionRows
        return VStack(alignment: .leading, spacing: 0) {
            sessionListControls(shown: rows.count)
            // The empty list has its own sentence; a header over nothing is furniture.
            if !rows.isEmpty { sessionColumnHeader }
            ForEach(rows) { row in
                SessionRowView(
                    row: row,
                    now: Date(),
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
    /// column; the fallback is the narrow row, which keeps only the chat and its cost
    /// on the first line and folds the rest into a caption.
    private var sessionColumnHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: OMSpacing.s) {
                Color.clear.frame(width: 16, height: 1)  // the row's chevron
                Text(sessionColumnTitle(0)).frame(minWidth: 160, alignment: .leading)
                Spacer(minLength: OMSpacing.s)
                Text(sessionColumnTitle(1)).frame(width: 104, alignment: .trailing)
                Text(sessionColumnTitle(2)).frame(width: 64, alignment: .trailing)
                Text(sessionColumnTitle(3)).frame(width: 84, alignment: .trailing)
                Text(sessionColumnTitle(4)).frame(width: 76, alignment: .trailing)
            }
            HStack(spacing: OMSpacing.s) {
                Color.clear.frame(width: 16, height: 1)
                Text(sessionColumnTitle(0))
                Spacer(minLength: OMSpacing.s)
                Text(sessionColumnTitle(4))
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
/// 612 pt here. The wide row asks for 520 and fits; `ViewThatFits` keeps the narrow
/// stack for anything smaller (and for a user who has widened the sidebar).
///
/// The expanded half is built into `@State` by `SessionDetail.build`, never computed in
/// `body`: one chat on this Mac launched 1,235 sub-agents, and the eight the table draws
/// have to be chosen off the main actor and once, not on every re-render of the list.
private struct SessionRowView: View {
    let row: SessionRow
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void

    private var session: SessionSummary { row.session }

    /// The expanded sections, built once per (chat, cap state) rather than per
    /// re-render: `session.agents` reaches 1,235 entries on this Mac, and sorting and
    /// formatting that inside `body` would run on every poll and every hover.
    @State private var detail = SessionDetail.empty
    @State private var showsAllAgents = false
    @State private var showsAllDays = false

    private struct DetailKey: Hashable {
        let id: String
        let expanded: Bool
        let allAgents: Bool
        let allDays: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            ViewThatFits(in: .horizontal) {
                wideSummary
                narrowSummary
            }
            if isExpanded { detailBlock }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionCopy.rowTitle(session))
        .accessibilityHint(isExpanded ? "Hides this chat's breakdown" : "Shows this chat's breakdown")
        .task(id: DetailKey(id: row.id, expanded: isExpanded, allAgents: showsAllAgents, allDays: showsAllDays)) {
            guard isExpanded else {
                detail = .empty
                // Collapsing forgets the caps too: reopening a chat should start from
                // the eight rows, not from a thousand somebody expanded last week.
                showsAllAgents = false
                showsAllDays = false
                return
            }
            let session = self.session
            let allAgents = showsAllAgents
            let allDays = showsAllDays
            detail = await Task.detached(priority: .userInitiated) {
                SessionDetail.build(session: session, allAgents: allAgents, allDays: allDays)
            }.value
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
            .frame(width: 16, height: 16)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OMSpacing.xs) {
                Text(SessionCopy.rowTitle(session))
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isTop {
                    OMChip(text: SessionCopy.topSpendChip, tint: .orange)
                }
                if let origin = SessionCopy.originChip(session.origin) {
                    OMChip(text: origin, tint: .secondary)
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

    private var wideSummary: some View {
        HStack(spacing: OMSpacing.s) {
            chevron
            titleBlock.frame(minWidth: 160, alignment: .leading)
            Spacer(minLength: OMSpacing.s)
            Text(lastActiveText)
                .font(OMFont.body).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            Text("\(session.turns)")
                .font(OMFont.numeral).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(TokenFormat.formatTokens(session.tokens.total))
                .font(OMFont.numeral).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(SessionCopy.cost(session.tokens.cost?.total))
                .font(OMFont.numeral).monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
    }

    /// The same five figures with the last three folded onto a caption line, for a
    /// window too narrow to hold five columns.
    private var narrowSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OMSpacing.s) {
                chevron
                titleBlock
                Spacer(minLength: OMSpacing.s)
                Text(SessionCopy.cost(session.tokens.cost?.total))
                    .font(OMFont.numeral).monospacedDigit()
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
            if !detail.agentRows.isEmpty { agentTable }
            if !detail.dayRows.isEmpty { dayTable }
        }
        .padding(.leading, 16 + OMSpacing.s)
        .padding(.top, OMSpacing.xs)
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
        ViewThatFits(in: .horizontal) {
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
