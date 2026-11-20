import SwiftUI

/// How the Live card orders its rows (spec 2026-11-19 agent resources § Where it shows): by
/// state, as before, or the session using the most CPU first after the rows that need the user.
enum AgentsLiveSort: String, CaseIterable, Sendable {
    case state, cpu
}

/// The Agents tab's Live card (`Dashboard-Agents(-Light).dc.html`; liquid-glass spec
/// § Screens, "Agents", and § Components, "Agent row (dashboard)"). It shows "Live" and
/// how many sessions are running, then one row per session: the 3.0 agent row at the
/// dashboard's size, with the provider logo and a state dot at its bottom-right, Needs
/// you in the accent, Allow filled and Deny on glass. Hairlines split the rows. The card
/// is full width, and the page scrolls, so the list never does. Finished sessions are
/// listed in History, which the header's "All sessions in History ›" opens. Every session
/// that runs in a terminal shows its CPU and memory beside the elapsed time, and from two
/// sessions, when one has figures, a State / CPU switch orders them (spec 2026-11-19 agent
/// resources).
struct AgentsLiveCard: View {
    let sessions: [AgentSession]
    /// The figures each live session shows, by session id (`AgentResourceMonitor.bySession`):
    /// on a shared tty only the most recently active session has them.
    var figures: [String: AgentResourceRules.Figures] = [:]
    /// The scale Settings › Menu bar › Agents chose (`SettingsStore.agentsCPUScale`).
    var scale: AgentCPUScale = .perCore
    /// `ProcessInfo.activeProcessorCount`, read by the host: Whole Mac divides by it.
    var cores: Int = 1
    /// The stored order, an `AgentsLiveSort` raw value kept under `sortKey`.
    var sort: Binding<String> = .constant(AgentsLiveSort.state.rawValue)
    /// The link's action. The host owns it: it knows the source filter, and the provider
    /// switch goes through `DashboardState` (`AgentsLinkRules`).
    let onShowHistory: () -> Void

    /// Rows from both sources can mix here (the filter's All), so each wears its logo.
    nonisolated static let showsProviderIcon = true

    /// The mockup draws these rows a size up from the popover's (28 pt logo, 13.5 pt title).
    nonisolated static let rowMetrics: OMAgentRowMetrics = .dashboard

    /// Where the order is kept between launches; Settings' Reset forgets it.
    nonisolated static let sortKey = "agentsLiveSort"

    /// The switch's two segments; their ids are what `selectedSort` reads.
    nonisolated static let sortItems = [
        OMSegmentItem(id: AgentsLiveSort.state.rawValue, title: AgentsCopy.sortByState),
        OMSegmentItem(id: AgentsLiveSort.cpu.rawValue, title: AgentsCopy.sortByCPU),
    ]

    /// The stored order; anything it does not name is State.
    nonisolated static func selectedSort(_ stored: String) -> AgentsLiveSort {
        AgentsLiveSort(rawValue: stored) ?? .state
    }

    /// The switch has something to order from two sessions up, and only when at least one of
    /// them has figures: without any, CPU order is state order.
    nonisolated static func showsSort(_ sessions: [AgentSession], figures: [String: AgentResourceRules.Figures]) -> Bool {
        sessions.count > 1 && sessions.contains { figures[$0.id] != nil }
    }

    /// The whole percent the CPU order compares: the per-core figure rounded, so
    /// jitter within a percent between two samples never swaps two rows. nil without a CPU figure.
    nonisolated static func wholePercent(_ cpu: Double?) -> Int? {
        guard let cpu, cpu.isFinite else { return nil }
        return Int(max(0, min(cpu, 1_000_000)).rounded())
    }

    /// State order (needs you, working, done, idle), most recent first inside each
    /// state: the popover's All tab, whichever source the filter shows. By CPU: the
    /// rows that carry an action (`AgentRowText.carriesAction`: a permission request, a question,
    /// Allow / Deny) keep the top in their state order and are never reordered by CPU, so a
    /// button does not move under the pointer; the others follow by whole percent, the busiest
    /// first, ties and the sessions with no CPU figure yet, or none at all, in state order.
    nonisolated static func rows(
        _ sessions: [AgentSession], sort: AgentsLiveSort = .state,
        figures: [String: AgentResourceRules.Figures] = [:]
    ) -> [AgentSession] {
        let byState = AgentsSection.rows(sessions, grouped: true)
        guard sort == .cpu else { return byState }
        let place = Dictionary(byState.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let acting = byState.filter(AgentRowText.carriesAction)
        let others = byState.filter { !AgentRowText.carriesAction($0) }
        return acting + others.sorted { a, b in
            let cpuA = wholePercent(figures[a.id]?.cpuPercent)
            let cpuB = wholePercent(figures[b.id]?.cpuPercent)
            switch (cpuA, cpuB) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (place[a.id] ?? 0) < (place[b.id] ?? 0)
            }
        }
    }

    /// A row's figures, "212% CPU · 3.4 GB", for every measured session; nothing for a session
    /// without a tty (Decision 3) or for an older session on a shared tty.
    nonisolated static func resourceText(
        for session: AgentSession, figures: [String: AgentResourceRules.Figures], scale: AgentCPUScale, cores: Int
    ) -> String? {
        AgentResourceCopy.dashboardText(figures[session.id], scale: scale, cores: cores)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AgentsLayout.cardHorizontalPadding)
            Color.clear
                .frame(height: AgentsLayout.liveHeaderGap)
                .accessibilityHidden(true)
            list
                .padding(.horizontal, AgentsLayout.liveRowsInset)
        }
        .padding(.top, AgentsLayout.cardVerticalPadding)
        .padding(.bottom, AgentsLayout.liveBottomPadding)
        .dashboardCard(padding: 0)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AgentsLayout.liveTitleCountSpacing) {
            Text(AgentsCopy.liveTitle)
                .font(.system(size: AgentsLayout.liveTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .accessibilityAddTraits(.isHeader)
            if let count = AgentsCopy.liveCount(sessions.count) {
                Text(count)
                    .font(.system(size: AgentsLayout.liveCountSize))
                    .monospacedDigit()
                    .foregroundStyle(.om(.secondary))
            }
            Spacer(minLength: OMSpacing.m)
            if Self.showsSort(sessions, figures: figures) {
                // The window's number keys belong to the sidebar and the source filter.
                OMSegmentedControl(
                    items: Self.sortItems,
                    selection: sort,
                    alwaysShowsTitles: true,
                    keyboardShortcuts: false,
                    accessibilityLabel: AgentsCopy.sortPickerName
                )
                .fixedSize()
            }
            Button(AgentsCopy.historyLink, action: onShowHistory)
                .buttonStyle(.omLink)
        }
    }

    @ViewBuilder
    private var list: some View {
        if sessions.isEmpty {
            Text(AgentsCopy.liveEmpty)
                .font(.system(size: AgentsLayout.liveCountSize))
                .foregroundStyle(.om(.secondary))
                .padding(.horizontal, OMAgentRow.horizontalPadding)
                .padding(.vertical, AgentsLayout.liveRowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let rows = Self.rows(sessions, sort: Self.selectedSort(sort.wrappedValue), figures: figures)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { hairline }
                    row(session)
                }
            }
        }
    }

    /// The 1 pt line between rows, on the rows' text edge: the card's 24 pt inset.
    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: 1)
            .padding(.horizontal, OMAgentRow.horizontalPadding)
    }

    /// Allow and Deny go through `AgentsSection.answer`, the popover's answer rule.
    private func row(_ session: AgentSession) -> some View {
        OMAgentRow(
            session: session,
            showsProviderIcon: Self.showsProviderIcon,
            metrics: Self.rowMetrics,
            resources: Self.resourceText(for: session, figures: figures, scale: scale, cores: cores),
            onAllow: { AgentsSection.answer(session, .allow) },
            onDeny: { AgentsSection.answer(session, .deny) },
            action: { SessionActivator.jump(to: session) }
        )
        .padding(.vertical, AgentsLayout.liveRowOuterPadding)
        .opacity(AgentsSection.rowOpacity(session.state))
    }
}

#if DEBUG
#Preview("Live card — dark") {
    AgentsLiveCard(sessions: AgentPreviewData.mixed, onShowHistory: {})
        .padding()
        .frame(width: 900)
        .preferredColorScheme(.dark)
}

#Preview("Live card — light") {
    AgentsLiveCard(sessions: AgentPreviewData.mixed, onShowHistory: {})
        .padding()
        .frame(width: 900)
}

#Preview("Live card — nothing running") {
    AgentsLiveCard(sessions: [], onShowHistory: {})
        .padding()
        .frame(width: 900)
}
#endif
