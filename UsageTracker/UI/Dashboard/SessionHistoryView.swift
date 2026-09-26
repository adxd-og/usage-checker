import SwiftUI

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
    @AppStorage(HistoryRules.viewModeKey) private var viewMode: HistoryViewMode = .chart

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
        let day: Date
    }

    private var cacheKey: CacheKey {
        CacheKey(
            service: dashboard.selectedService,
            range: range,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            bucketIDs: dashboard.quotaBuckets.map(\.id),
            day: HistoryRules.cacheDay(now: Date(), calendar: .current)
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
        let range = self.range
        let built = await Task.detached(priority: .userInitiated) { () -> QuotaHistoryCache in
            // One clock for the lines and the axis (`HistoryRules.quotaChart`).
            let chart = HistoryRules.quotaChart(
                records: records, buckets: buckets, range: range, now: Date(), calendar: .current
            )
            return QuotaHistoryCache(series: chart.series, domain: chart.domain)
        }.value
        // See `DerivedCacheGate`: a pass for the provider or range just left must not
        // land after the new one's.
        guard DerivedCacheGate.canPublish(
            started: started, current: cacheKey, cancelled: Task.isCancelled
        ) else { return }
        quota = built
    }

    var body: some View {
        // Measured here, once, off the width the tab is given: the chat list's column
        // header and every one of its rows then draw to the same decision.
        GeometryReader { proxy in
            scrollBody(isWide: HistoryLayout.isWideList(detailWidth: proxy.size.width))
        }
    }

    private func scrollBody(isWide: Bool) -> some View {
        // One clock per pass: the chart's days, its total and today's bar agree on
        // where today ends.
        let now = Date()
        return ScrollView {
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
                    if viewMode == .calendar {
                        // Cost only, whatever the unit switch says (spec § Decisions,
                        // "Calendar in Tokens mode").
                        ActivityGridView(dashboard: dashboard, range: range)
                    } else if showsQuota {
                        HistoryQuotaCard(
                            series: quota.series,
                            domain: quota.domain,
                            range: range,
                            providerName: dashboard.displayName(for: dashboard.selectedService)
                        )
                    } else {
                        HistoryChartCard(
                            days: HistoryRules.days(
                                daily: dashboard.cliBreakdown?.daily ?? [],
                                range: range, now: now, calendar: .current
                            ),
                            mode: mode,
                            range: range,
                            now: now,
                            command: DashboardState.cliCommandName(for: dashboard.selectedService)
                        )
                    }
                    if showsQuota {
                        quotaOnlyNote
                    } else if hasSessionLog {
                        // The chat list sits under the chart or the calendar (spec
                        // § Screens, "History · Chart"), for the providers whose logs
                        // name a chat.
                        HistorySessionsCard(dashboard: dashboard, isWide: isWide)
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

    /// Chart/Calendar for every provider, Cost/Tokens only over a cost chart
    /// (`HistoryRules.showsModePicker`), then the range.
    @ViewBuilder
    private var pickers: some View {
        viewPicker
        if HistoryRules.showsModePicker(view: viewMode, showsQuota: showsQuota) { modePicker }
        RangePicker(range: $dashboard.range, ranges: HistoryRules.ranges)
    }

    /// Chart or Calendar. A quota-only provider has it too: its calendar colours days
    /// by their daily peak (spec § Screens, "History · Calendar").
    private var viewPicker: some View {
        OMSegmentedControl(
            items: HistoryViewMode.allCases.map { OMSegmentItem(id: $0.rawValue, title: $0.displayName) },
            selection: Binding(
                get: { viewMode.rawValue },
                set: { viewMode = HistoryViewMode(rawValue: $0) ?? viewMode }
            ),
            alwaysShowsTitles: true,
            keyboardShortcuts: false,
            accessibilityLabel: HistoryCopy.viewPickerLabel
        )
        .fixedSize()
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

    /// Why a quota-only provider shows no dollars and no chats: the sidebar's old
    /// "usage history only" fact (spec § Removals) lands here, under the chart.
    private var quotaOnlyNote: some View {
        Text(HistoryCopy.quotaOnlyNote(provider: dashboard.selectedService))
            .font(.system(size: HistoryLayout.noteSize))
            .foregroundStyle(.om(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, HistoryLayout.noteInset)
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

// MARK: - Quota cache (computed off the main thread, then cached in @State)

/// The quota chart's lines and the domain they were built for, off the main actor by
/// `HistoryRules.quotaChart`; the card draws this domain, not one of its own.
private struct QuotaHistoryCache: Sendable {
    let series: [HistoryQuotaSeries]
    let domain: ClosedRange<Date>

    static let empty = QuotaHistoryCache(series: [], domain: Date.distantPast...Date.distantPast)
}
