import SwiftUI

/// History's chat list (liquid-glass spec § Screens, "History · Chart" and "History ·
/// Session expanded"): a card under the chart for the providers whose logs name a chat.
/// The rows are `SessionListRule`'s pick, or every chat in the order the sort asks for.
/// Every string comes from `HistoryCopy` or `SessionCopy`; this view decides layout.
struct HistorySessionsCard: View {
    @ObservedObject var dashboard: DashboardState
    /// The page's one layout decision (`HistoryLayout.isWideList`): the column header and
    /// every row obey it, so a title never stands over a column that is not drawn.
    let isWide: Bool

    /// Which chats are open. Per row and not persisted: an expanded chat is a decision
    /// about *this* chat, and a tab that reopens with four rows unfolded is noise.
    @State private var expandedSessionIDs: Set<String> = []
    /// Whether "Show all N" has been pressed. Reset whenever the provider or the range
    /// changes — the number in the link would otherwise be about a different list.
    @State private var showsAllSessions = false
    /// The full list's order. Persisted: it is a question the user asks repeatedly
    /// ("what has this cost me?"), not a per-visit choice.
    @AppStorage("historySessionSort") private var sessionSort: SessionListRule.Sort = .recent

    /// Everything the list's contents are keyed against. `updatedAt` is the aggregator's
    /// own ingest stamp, so a poll that changed nothing re-triggers nothing.
    private struct SessionsKey: Hashable {
        let service: String
        let range: TimeRange
        let updatedAt: Date
    }

    /// Just the two things that invalidate the list's controls, as opposed to its
    /// contents.
    private struct SessionScope: Hashable {
        let service: String
        let range: TimeRange
    }

    private var rows: [SessionRow] {
        showsAllSessions
            ? SessionListRule.sorted(dashboard.sessions, by: sessionSort)
            : SessionListRule.pick(sessions: dashboard.sessions)
    }

    var body: some View {
        let rows = self.rows
        return VStack(alignment: .leading, spacing: 0) {
            header(shown: rows.count)
            if rows.isEmpty {
                placeholder
            } else {
                columnHeader
                ForEach(rows) { row in
                    HistorySessionRow(
                        row: row,
                        now: Date(),
                        isWide: isWide,
                        isExpanded: expandedSessionIDs.contains(row.id),
                        toggle: { toggle(row.id) }
                    )
                    if row.id != rows.last?.id { hairline }
                }
            }
        }
        .padding(HistoryLayout.sessionsCardPadding)
        .dashboardCard(padding: 0)
        // Provider or range changed: the link's "Show all 34" and any open row are about
        // a list that no longer exists.
        .task(id: SessionScope(service: dashboard.selectedService, range: dashboard.range)) {
            showsAllSessions = false
            expandedSessionIDs = []
        }
        .task(id: SessionsKey(
            service: dashboard.selectedService,
            range: dashboard.range,
            updatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast
        )) {
            await dashboard.refreshSessions()
        }
    }

    /// "Sessions  4 of 103" on the left, "Show all 103 ›" on the right (`-Cost`), and the
    /// sort once the whole list is out.
    private func header(shown: Int) -> some View {
        let total = dashboard.sessions.count
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(HistoryCopy.sessionsTitle)
                .font(.system(size: HistoryLayout.cardTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
            if total > 0 {
                Text(HistoryCopy.sessionCount(shown: shown, total: total))
                    .font(.system(size: HistoryLayout.cardCaptionSize))
                    .foregroundStyle(.om(.secondary))
            }
            Spacer(minLength: HistoryLayout.controlSpacing)
            if showsAllSessions { sortPicker }
            if showsAllSessions || SessionListRule.canShowAll(shown: shown, total: total) {
                Button(SessionCopy.showAll(count: total, expanded: showsAllSessions)) {
                    showsAllSessions.toggle()
                }
                .buttonStyle(.omLink)
            }
        }
        .padding(.bottom, HistoryLayout.sessionsHeaderBottom)
    }

    private var sortPicker: some View {
        OMSegmentedControl(
            items: SessionListRule.Sort.allCases.map { OMSegmentItem(id: $0.rawValue, title: $0.displayName) },
            selection: Binding(
                get: { sessionSort.rawValue },
                set: { sessionSort = SessionListRule.Sort(rawValue: $0) ?? sessionSort }
            ),
            alwaysShowsTitles: true,
            keyboardShortcuts: false,
            accessibilityLabel: HistoryCopy.sortPickerLabel
        )
        .fixedSize()
    }

    /// The column titles at the rows' own widths, so a title sits over its column.
    private var columnHeader: some View {
        let titles = HistoryCopy.sessionColumns
        return Group {
            if isWide {
                HStack(spacing: HistoryLayout.columnGap) {
                    Color.clear.frame(width: HistoryLayout.chevronWidth, height: 1)
                    Text(titles[0])
                        .frame(minWidth: HistoryLayout.titleMinWidth, maxWidth: .infinity, alignment: .leading)
                    Text(titles[1]).frame(width: HistoryLayout.lastActiveWidth, alignment: .trailing)
                    Text(titles[2]).frame(width: HistoryLayout.turnsWidth, alignment: .trailing)
                    Text(titles[3]).frame(width: HistoryLayout.tokensWidth, alignment: .trailing)
                    Text(titles[4]).frame(width: HistoryLayout.costWidth, alignment: .trailing)
                }
            } else {
                HStack(spacing: HistoryLayout.columnGap) {
                    Color.clear.frame(width: HistoryLayout.chevronWidth, height: 1)
                    Text(titles[0])
                    Spacer(minLength: HistoryLayout.columnGap)
                    Text(titles[4])
                }
            }
        }
        .font(.system(size: HistoryLayout.columnTitleSize, weight: .semibold))
        .foregroundStyle(.om(.secondary))
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { hairline }
    }

    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: 1)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.om(.muted))
            Text(SessionCopy.emptyTitle)
                .foregroundStyle(.om(.secondary))
            if let hint = SessionCopy.emptyHint(providerID: dashboard.selectedService) {
                Text(hint)
                    .font(OMFont.body)
                    .foregroundStyle(.om(.secondary))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.bottom, HistoryLayout.rowVerticalPadding)
    }

    private func toggle(_ id: String) {
        if expandedSessionIDs.contains(id) {
            expandedSessionIDs.remove(id)
        } else {
            expandedSessionIDs.insert(id)
        }
    }
}

/// One chat, collapsed to a line and expanded under it. `isWide` arrives from the page:
/// a row that measured itself would disagree with the header above it, because what it
/// measures is its own chat title.
///
/// The expanded half is built into `@State` off the main actor, never in `body`: one
/// chat on this Mac launched 1,235 sub-agents, and the rows the tables draw have to be
/// chosen once, not on every re-render of the list.
private struct HistorySessionRow: View {
    let row: SessionRow
    let now: Date
    let isWide: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    private var session: SessionSummary { row.session }

    @State private var detail = HistorySessionDetail.empty
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
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isWide { wideSummary } else { narrowSummary }
            }
            .padding(.vertical, HistoryLayout.rowVerticalPadding)
            // The summary line answers a click; the open chat under it does not, so
            // selecting a figure there never folds the row.
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if isExpanded { detailBlock }
        }
        // A group named after the chat; the hint is on `rowToggle`, the one control.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionCopy.rowTitle(session))
        .task(id: detailKey) {
            guard isExpanded else {
                detail = .empty
                // Collapsing forgets the caps too: reopening a chat should start from
                // the capped rows, not from a thousand somebody expanded last week.
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
            let now = self.now
            let built = await Task.detached(priority: .userInitiated) {
                HistorySessionDetail.build(
                    session: session, allAgents: allAgents, allDays: allDays,
                    allModels: allModels, now: now
                )
            }.value
            // See `DerivedCacheGate`: a collapse, a lifted cap or a newer summary of the
            // chat restarts this task, but the await does not stop for that.
            guard DerivedCacheGate.canPublish(
                started: started, current: detailKey, cancelled: Task.isCancelled
            ) else { return }
            detail = built
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.om(.secondary))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: HistoryLayout.chevronWidth, height: HistoryLayout.chevronWidth)
    }

    /// The chevron and the chat's name, as the row's one control: Tab reaches it and
    /// VoiceOver can press it, which a tap gesture on the row cannot offer.
    private func rowToggle<Title: View>(_ title: Title) -> some View {
        Button(action: toggle) {
            HStack(spacing: HistoryLayout.columnGap) {
                chevron
                title
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SessionCopy.rowTitle(session))
        .accessibilityHint(SessionCopy.rowActionName(expanded: isExpanded))
        .help(SessionCopy.rowActionName(expanded: isExpanded))
    }

    /// The chat's name over its project line. The name is the one thing on the row with
    /// no length limit, so it yields and truncates at the tail: what tells two chats
    /// apart is how they open.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SessionCopy.rowTitle(session))
                .font(.system(size: HistoryLayout.rowTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(HistoryCopy.sessionSubtitle(
                project: SessionCopy.projectName(providerID: session.providerID, projectSlug: session.projectSlug),
                isTop: row.isTop,
                origin: session.origin
            ))
            .font(.system(size: HistoryLayout.rowSubtitleSize))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
        }
    }

    private var lastActiveText: String {
        SessionCopy.lastActive(session.lastAt, now: now)
    }

    /// The mockup's grid: chevron, name, Last active, Turns, Tokens, Cost. The figures
    /// keep their widths; the name takes what is left.
    private var wideSummary: some View {
        HStack(spacing: HistoryLayout.columnGap) {
            rowToggle(titleBlock.frame(minWidth: HistoryLayout.titleMinWidth, maxWidth: .infinity, alignment: .leading))
                .layoutPriority(0)
            Text(lastActiveText)
                .font(.system(size: HistoryLayout.cardCaptionSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
                .frame(width: HistoryLayout.lastActiveWidth, alignment: .trailing)
            Text(HistoryCopy.count(session.turns))
                .font(OMFont.numerals(size: HistoryLayout.rowTitleSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
                .frame(width: HistoryLayout.turnsWidth, alignment: .trailing)
            Text(TokenFormat.formatTokens(session.tokens.total))
                .font(OMFont.numerals(size: HistoryLayout.rowTitleSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
                .frame(width: HistoryLayout.tokensWidth, alignment: .trailing)
            Text(SessionCopy.cost(session.tokens.cost?.total))
                .font(OMFont.numerals(size: HistoryLayout.rowCostSize, weight: .bold))
                .foregroundStyle(.om(.text))
                .frame(width: HistoryLayout.costWidth, alignment: .trailing)
        }
    }

    /// The same figures for a column too narrow for five: the cost stays on the line,
    /// the rest fold onto a caption.
    private var narrowSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: HistoryLayout.columnGap) {
                rowToggle(titleBlock).layoutPriority(0)
                Spacer(minLength: HistoryLayout.columnGap)
                Text(SessionCopy.cost(session.tokens.cost?.total))
                    .font(OMFont.numerals(size: HistoryLayout.rowCostSize, weight: .bold))
                    .foregroundStyle(.om(.text))
                    .fixedSize()
                    .layoutPriority(1)
            }
            Text(HistoryCopy.narrowCaption(
                lastActive: lastActiveText, turns: session.turns, tokens: session.tokens.total
            ))
            .font(.system(size: HistoryLayout.rowSubtitleSize))
            .foregroundStyle(.om(.secondary))
            .padding(.leading, HistoryLayout.chevronWidth + HistoryLayout.columnGap)
        }
    }

    // MARK: Expanded chat

    /// The open chat (`Dashboard-History-Chats`): where the money went, By model and By
    /// day side by side (stacked when the column is too narrow for both), then the
    /// sub-agents.
    private var detailBlock: some View {
        VStack(alignment: .leading, spacing: HistoryLayout.panelSectionSpacing) {
            moneySection
            if !detail.modelRows.isEmpty || !detail.dayRows.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: HistoryLayout.panelTablesGap) {
                        modelSection
                        daySection
                    }
                    VStack(alignment: .leading, spacing: HistoryLayout.panelSectionSpacing) {
                        modelSection
                        daySection
                    }
                }
            }
            if !detail.agentRows.isEmpty { agentSection }
        }
        .padding(HistoryLayout.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HistoryLayout.panelRadius, style: .continuous)
                .fill(.om(.insetFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HistoryLayout.panelRadius, style: .continuous)
                .strokeBorder(.om(.contentBorder), lineWidth: 1)
        )
        .padding(.leading, HistoryLayout.panelLeadingInset)
        .padding(.bottom, HistoryLayout.panelBottomInset)
    }

    private func sectionTitle(_ title: String, count: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: HistoryLayout.cardCaptionSize, weight: .semibold))
                .foregroundStyle(.om(.text))
            if let count {
                Text(count)
                    .font(.system(size: HistoryLayout.cardCaptionSize, weight: .medium))
                    .foregroundStyle(.om(.secondary))
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var moneySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(detail.money.title, count: detail.money.total)
            if detail.money.total != nil { moneyBar }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: HistoryLayout.panelColumnGap, alignment: .leading),
                    count: 5
                ),
                alignment: .leading,
                spacing: HistoryLayout.panelColumnGap
            ) {
                ForEach(detail.money.segments) { segment in
                    moneyCell(label: segment.category.label, token: segment.category.token,
                              tokens: segment.tokens, note: segment.cost, noteIsFigure: true)
                }
                if let thinking = detail.money.thinking {
                    moneyCell(label: HistoryCopy.thinkingLabel, token: .muted,
                              tokens: thinking, note: HistoryCopy.thinkingNote, noteIsFigure: false)
                }
            }
        }
    }

    private var moneyBar: some View {
        GeometryReader { proxy in
            let segments = detail.money.segments
            let widths = HistoryMoneySplit.widths(
                shares: segments.map(\.share), in: proxy.size.width,
                minimum: HistoryLayout.moneyBarMinimum, gap: HistoryLayout.moneyBarGap
            )
            HStack(spacing: HistoryLayout.moneyBarGap) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .fill(.om(segment.category.token))
                        .frame(width: widths[index])
                }
            }
        }
        .frame(height: HistoryLayout.moneyBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: HistoryLayout.moneyBarHeight / 2, style: .continuous))
        .accessibilityHidden(true)
    }

    private func moneyCell(label: String, token: OMColorToken, tokens: String, note: String?, noteIsFigure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(.om(token)).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: HistoryLayout.rowSubtitleSize))
                    .foregroundStyle(.om(.secondary))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tokens)
                    .font(OMFont.numerals(size: 17, weight: .semibold))
                    .foregroundStyle(.om(.text))
                if let note {
                    Text(note)
                        .font(noteIsFigure
                              ? OMFont.numerals(size: HistoryLayout.cardCaptionSize, weight: .semibold)
                              : .system(size: HistoryLayout.rowSubtitleSize))
                        .foregroundStyle(.om(.secondary))
                }
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if !detail.modelRows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(SessionCopy.byModelTitle, count: nil)
                VStack(alignment: .leading, spacing: 0) {
                    tableHeader(SessionCopy.modelColumnTitles)
                    ForEach(detail.modelRows) { columns in
                        shareRow(
                            name: modelName(columns),
                            share: detail.modelShares[columns.id] ?? 0,
                            turns: columns.turns, tokens: columns.tokens, cost: columns.cost,
                            isLast: columns.id == detail.modelRows.last?.id
                        )
                    }
                }
                if detail.hiddenModels > 0 || showsAllModels {
                    moreButton(SessionCopy.showAllModels(count: detail.totalModels, expanded: showsAllModels)) {
                        showsAllModels.toggle()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var daySection: some View {
        if !detail.dayRows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(SessionCopy.byDayTitle, count: nil)
                VStack(alignment: .leading, spacing: 0) {
                    tableHeader(HistoryCopy.dayColumns)
                    ForEach(detail.dayRows) { columns in
                        shareRow(
                            name: Text(columns.day)
                                .font(.system(size: 13, weight: columns.id == detail.todayDayID ? .bold : .semibold))
                                .foregroundStyle(.om(.text)),
                            share: detail.dayShares[columns.id] ?? 0,
                            turns: columns.turns, tokens: columns.tokens, cost: columns.cost,
                            isLast: columns.id == detail.dayRows.last?.id
                        )
                    }
                }
                if detail.hiddenDays > 0 || showsAllDays {
                    moreButton(SessionCopy.showAllDays(count: detail.totalDays, expanded: showsAllDays)) {
                        showsAllDays.toggle()
                    }
                }
            }
        }
    }

    private func modelName(_ columns: SessionModelColumns) -> some View {
        HStack(spacing: 4) {
            Text(columns.model)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
            if let effort = columns.effort {
                Text(effort)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
            }
        }
    }

    private func title(_ titles: [String], _ index: Int) -> String {
        titles.indices.contains(index) ? titles[index] : ""
    }

    private func tableHeader(_ titles: [String]) -> some View {
        HStack(spacing: HistoryLayout.panelColumnGap) {
            Text(title(titles, 0))
                .frame(minWidth: HistoryLayout.panelNameMinWidth, maxWidth: .infinity, alignment: .leading)
            Text(title(titles, 1)).frame(width: HistoryLayout.panelTurnsWidth, alignment: .trailing)
            Text(title(titles, 2)).frame(width: HistoryLayout.panelTokensWidth, alignment: .trailing)
            Text(title(titles, 3)).frame(width: HistoryLayout.panelCostWidth, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.om(.secondary))
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { panelHairline }
    }

    /// A By model or By day row: the name over a bar of its share of the table's most
    /// expensive row, then the three figures.
    private func shareRow<Name: View>(
        name: Name, share: Double, turns: String, tokens: String, cost: String, isLast: Bool
    ) -> some View {
        HStack(spacing: HistoryLayout.panelColumnGap) {
            VStack(alignment: .leading, spacing: 5) {
                name
                shareBar(share)
            }
            .frame(minWidth: HistoryLayout.panelNameMinWidth, maxWidth: .infinity, alignment: .leading)
            Text(turns)
                .font(OMFont.numerals(size: 13, weight: .medium))
                .foregroundStyle(.om(.secondary))
                .frame(width: HistoryLayout.panelTurnsWidth, alignment: .trailing)
            Text(tokens)
                .font(OMFont.numerals(size: 13, weight: .medium))
                .foregroundStyle(.om(.secondary))
                .frame(width: HistoryLayout.panelTokensWidth, alignment: .trailing)
            Text(cost)
                .font(OMFont.numerals(size: 13, weight: .semibold))
                .foregroundStyle(.om(.text))
                .frame(width: HistoryLayout.panelCostWidth, alignment: .trailing)
        }
        .padding(.vertical, HistoryLayout.panelRowVerticalPadding)
        .overlay(alignment: .bottom) { if !isLast { panelHairline } }
    }

    private func shareBar(_ share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.om(.track))
                Capsule().fill(.om(.accent)).frame(width: proxy.size.width * CGFloat(share))
            }
        }
        .frame(height: HistoryLayout.shareBarHeight)
        .accessibilityHidden(true)
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(HistoryCopy.subAgentsTitle, count: HistoryCopy.count(detail.totalAgents))
            VStack(alignment: .leading, spacing: 0) {
                if isWide { agentHeader }
                ForEach(detail.agentRows) { agent in
                    agentRow(agent, isLast: agent.id == detail.agentRows.last?.id)
                }
            }
            if detail.hiddenAgents > 0 || showsAllAgents {
                moreButton(SessionCopy.showAllAgents(count: detail.totalAgents, expanded: showsAllAgents)) {
                    showsAllAgents.toggle()
                }
            }
        }
    }

    private var agentHeader: some View {
        let titles = HistoryCopy.agentColumns
        return HStack(spacing: HistoryLayout.panelColumnGap) {
            Text(title(titles, 0))
                .frame(minWidth: HistoryLayout.panelNameMinWidth, maxWidth: .infinity, alignment: .leading)
            Text(title(titles, 1)).frame(width: HistoryLayout.agentModelWidth, alignment: .trailing)
            Text(title(titles, 2)).frame(width: HistoryLayout.agentEffortWidth, alignment: .trailing)
            Text(title(titles, 3)).frame(width: HistoryLayout.agentTurnsWidth, alignment: .trailing)
            Text(title(titles, 4)).frame(width: HistoryLayout.agentTokensWidth, alignment: .trailing)
            Text(title(titles, 5)).frame(width: HistoryLayout.agentCostWidth, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.om(.secondary))
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { panelHairline }
    }

    private func agentRow(_ agent: HistoryAgentRow, isLast: Bool) -> some View {
        Group {
            if isWide {
                HStack(spacing: HistoryLayout.panelColumnGap) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: agent.isMain ? .semibold : .medium))
                        .foregroundStyle(.om(.text))
                        .lineLimit(1)
                        .frame(minWidth: HistoryLayout.panelNameMinWidth, maxWidth: .infinity, alignment: .leading)
                    Text(agent.model)
                        .font(.system(size: HistoryLayout.cardCaptionSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                        .frame(width: HistoryLayout.agentModelWidth, alignment: .trailing)
                    Text(agent.effort)
                        .font(.system(size: HistoryLayout.cardCaptionSize))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                        .frame(width: HistoryLayout.agentEffortWidth, alignment: .trailing)
                    Text(agent.turns)
                        .font(OMFont.numerals(size: 13, weight: .medium))
                        .foregroundStyle(.om(.secondary))
                        .frame(width: HistoryLayout.agentTurnsWidth, alignment: .trailing)
                    Text(agent.tokens)
                        .font(OMFont.numerals(size: 13, weight: .medium))
                        .foregroundStyle(.om(.secondary))
                        .frame(width: HistoryLayout.agentTokensWidth, alignment: .trailing)
                    Text(agent.cost)
                        .font(OMFont.numerals(size: 13, weight: .semibold))
                        .foregroundStyle(.om(.text))
                        .frame(width: HistoryLayout.agentCostWidth, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(agent.name)
                            .font(.system(size: 13, weight: agent.isMain ? .semibold : .medium))
                            .foregroundStyle(.om(.text))
                            .lineLimit(1)
                        Spacer()
                        Text(agent.cost)
                            .font(OMFont.numerals(size: 13, weight: .semibold))
                            .foregroundStyle(.om(.text))
                    }
                    Text(HistoryCopy.agentCaption(agent))
                        .font(.system(size: HistoryLayout.rowSubtitleSize))
                        .foregroundStyle(.om(.secondary))
                }
            }
        }
        .padding(.vertical, HistoryLayout.panelRowVerticalPadding)
        .overlay(alignment: .bottom) { if !isLast { panelHairline } }
    }

    /// "Show all 23 sub-agents": accent text with no chevron, as the mockup draws it
    /// inside a table (the header's "Show all 103 ›" is the link style).
    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: HistoryLayout.cardCaptionSize, weight: .semibold))
            .foregroundStyle(.om(.accentText))
            .padding(.top, 4)
    }

    private var panelHairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: 1)
    }

    // MARK: End of expanded chat
}
