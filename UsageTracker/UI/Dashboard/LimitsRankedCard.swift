import SwiftUI

/// "What filled this week" (`Dashboard-Limits(-Light).dc.html`): the window's chats
/// ranked by their share, `LimitsRules.rowCap` of them until "Show all". A wide card gives
/// the project its own column; a narrow one folds it under the name
/// (`LimitsLayout.isWideRows`, measured once by the page). The rows are `LimitsRules`',
/// the words `LimitsCopy`'s.
struct LimitsRankedCard: View {
    /// The share on screen. Its rows are built when it, or the cap, changes (`rowsKey`),
    /// never on a plain re-render: a month can hold thousands of chats.
    let load: DashboardState.LimitShareLoad
    let title: String
    /// On the title's baseline: how far the window is, or what the shares are of.
    let trailing: String
    /// Earlier this month and Outside this Mac, under the ranked rows.
    let tail: [LimitsRow]
    /// In place of the rows when the window has none.
    let emptyText: String
    /// Under everything: what the rows' dollars are, where the first card does not say it.
    let footnote: String?
    let isWide: Bool
    /// Chats or Projects; the page keeps it per provider.
    @Binding var grouping: LimitsGrouping

    @State private var showsAll = false
    /// The rows on screen, formatted; nil until the first build.
    @State private var ranked: LimitsRankedRows?
    /// The chats open on their stretches. Per card: a new provider, window, period or
    /// measure is a new card (`.id(load.query)`), with every chat closed.
    @State private var expandedChatIDs: Set<String> = []
    /// The open chats' stretch rows, by chat id, formatted off the main actor
    /// (`stretchRowsKey`).
    @State private var stretchRows: [String: [LimitsRow]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, LimitsLayout.rankedHeaderBottom)
            if let ranked {
                rowsSection(ranked)
            }
            ForEach(tail) { row in
                tailRow(row)
            }
            if let footnote {
                Text(footnote)
                    .font(.system(size: LimitsLayout.figureCaptionSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, LimitsLayout.rowVerticalPadding)
            }
        }
        .padding(LimitsLayout.rankedCardPadding)
        .dashboardCard(padding: 0)
        .task(id: rowsKey) {
            ranked = LimitsRules.rows(
                of: load.share, grouping: grouping, serviceID: load.serviceID, showsAll: showsAll
            )
        }
        .task(id: stretchRowsKey) {
            await buildStretchRows()
        }
    }

    /// What the rows are built from: the load (what it answered, and the share itself, so a re-cut of an expired window with the same query still rebuilds), the
    /// cap and the grouping.
    private struct RowsKey: Equatable {
        let query: LimitsQuery
        let share: LimitShare
        let showsAll: Bool
        let grouping: LimitsGrouping
    }

    private var rowsKey: RowsKey {
        RowsKey(query: load.query, share: load.share, showsAll: showsAll, grouping: grouping)
    }

    /// What the stretch rows are built from: the load's stretches and which chats are
    /// open. A share cut again comes with its stretches cut again.
    private struct StretchRowsKey: Equatable {
        let stretches: [String: [ChatStretch]]
        let open: Set<String>
    }

    private var stretchRowsKey: StretchRowsKey {
        StretchRowsKey(stretches: load.stretches, open: expandedChatIDs)
    }

    /// The open chats' stretch rows, formatted on a detached task: a long chat has dozens
    /// of stretches, and a month thousands. A newer key's build cancels this one, which
    /// then publishes nothing.
    private func buildStretchRows() async {
        let stretches = load.stretches
        let open = expandedChatIDs
        let rows = await Task.detached(priority: .userInitiated) {
            LimitsRules.stretchRows(chatIDs: open, stretches: stretches, now: Date())
        }.value
        guard !Task.isCancelled else { return }
        stretchRows = rows
    }

    /// The ranked rows and "Show all", or the sentence for a window with none.
    @ViewBuilder
    private func rowsSection(_ ranked: LimitsRankedRows) -> some View {
        if ranked.rows.isEmpty {
            Text(emptyText)
                .font(.system(size: LimitsLayout.rowSubtitleSize))
                .foregroundStyle(.om(.secondary))
                .padding(.vertical, LimitsLayout.rowVerticalPadding)
        } else {
            ForEach(Array(ranked.rows.enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 0) {
                    if grouping == .chats {
                        chatRow(row)
                        if expandedChatIDs.contains(row.id) {
                            ForEach(stretchRows[row.id] ?? []) { stretch in
                                stretchRow(stretch)
                            }
                        }
                    } else {
                        rankedRow(row)
                    }
                }
                .overlay(alignment: .top) {
                    if index > 0 { hairline }
                }
            }
            if LimitsRules.canShowAll(count: ranked.total) {
                Button(LimitsCopy.showAll(count: ranked.total, expanded: showsAll)) {
                    showsAll.toggle()
                }
                .buttonStyle(.omLink)
                .padding(.vertical, LimitsLayout.rowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { hairline }
            }
        }
    }

    /// The title with its caption, and the Chats / Projects switch at the trailing edge.
    /// The switch goes under the title before either is clipped.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: LimitsLayout.titleSpacing) {
                titleBlock
                Spacer(minLength: LimitsLayout.titleSpacing)
                groupingSwitch
            }
            VStack(alignment: .leading, spacing: LimitsLayout.titleSpacing) {
                titleBlock
                groupingSwitch
            }
        }
    }

    private var groupingSwitch: some View {
        OMSegmentedControl(
            items: LimitsGrouping.allCases.map { OMSegmentItem(id: $0.rawValue, title: LimitsCopy.groupingName($0)) },
            selection: Binding(
                get: { grouping.rawValue },
                set: { grouping = LimitsGrouping(rawValue: $0) ?? grouping }
            ),
            alwaysShowsTitles: true,
            keyboardShortcuts: false,
            accessibilityLabel: LimitsCopy.groupingPickerLabel
        )
        .fixedSize()
    }

    private var titleBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: LimitsLayout.rankedTitleSpacing) {
            Text(title)
                .font(.system(size: LimitsLayout.cardTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(trailing)
                .font(.system(size: LimitsLayout.cardCaptionSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
        }
    }

    /// Name · project · share · dollars: the mockup's `minmax(0, 1fr) 280px 96px 80px`.
    /// Narrow, the project goes under the name and the figures stay on the name's line.
    private func rankedRow(_ row: LimitsRow) -> some View {
        HStack(alignment: isWide ? .center : .firstTextBaseline, spacing: LimitsLayout.columnGap) {
            if isWide {
                nameText(row.title)
                    .frame(minWidth: LimitsLayout.titleMinWidth, maxWidth: .infinity, alignment: .leading)
                subtitleText(row.subtitle)
                    .frame(width: LimitsLayout.projectWidth, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: LimitsLayout.rowLineSpacing) {
                    nameText(row.title)
                    subtitleText(row.subtitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            figures(row)
        }
        .padding(.vertical, LimitsLayout.rowVerticalPadding)
        .help(row.title)
        .accessibilityElement(children: .combine)
    }

    /// Earlier this month and Outside this Mac: what each stands for under its name at any
    /// width (the mockup's `minmax(0, 1fr) 96px 80px`), a hairline above.
    private func tailRow(_ row: LimitsRow) -> some View {
        HStack(alignment: .center, spacing: LimitsLayout.columnGap) {
            VStack(alignment: .leading, spacing: LimitsLayout.rowLineSpacing) {
                nameText(row.title)
                subtitleText(row.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            figures(row)
        }
        .padding(.leading, chatIndent)
        .padding(.vertical, LimitsLayout.tailRowVerticalPadding)
        .overlay(alignment: .top) { hairline }
        .accessibilityElement(children: .combine)
    }

    /// How far the rows under the list stand in: past the chevrons, while chats can open.
    private var chatIndent: CGFloat {
        grouping == .chats ? LimitsLayout.chatIndent : 0
    }

    private func toggle(_ chatID: String) {
        if expandedChatIDs.contains(chatID) {
            expandedChatIDs.remove(chatID)
        } else {
            expandedChatIDs.insert(chatID)
        }
    }

    /// A chat's row with the chevron that opens its stretches (spec 2026-10-16 limit
    /// analytics § The tab, item 5). The whole line answers a click; the chevron is the one
    /// control Tab and VoiceOver reach.
    private func chatRow(_ row: LimitsRow) -> some View {
        let isExpanded = expandedChatIDs.contains(row.id)
        return HStack(alignment: .center, spacing: LimitsLayout.chevronGap) {
            Button {
                toggle(row.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: LimitsLayout.chevronSize, weight: .semibold))
                    .foregroundStyle(.om(.secondary))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: LimitsLayout.chevronWidth, height: LimitsLayout.chevronWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.title)
            .accessibilityHint(LimitsCopy.stretchToggle(expanded: isExpanded))
            .help(LimitsCopy.stretchToggle(expanded: isExpanded))
            rankedRow(row)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(row.id) }
    }

    /// One stretch under its open chat: its prompt over its hours, how it began and its
    /// cold start, then its share and dollars in the chat's columns.
    private func stretchRow(_ row: LimitsRow) -> some View {
        HStack(alignment: .center, spacing: LimitsLayout.columnGap) {
            VStack(alignment: .leading, spacing: LimitsLayout.rowLineSpacing) {
                Text(row.title)
                    .font(.system(size: LimitsLayout.stretchTitleSize, weight: .medium))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitleText(row.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            figures(row)
        }
        .padding(.leading, chatIndent)
        .padding(.vertical, LimitsLayout.stretchRowVerticalPadding)
        .help(row.title)
        .accessibilityElement(children: .combine)
    }

    /// The share and its dollars, right-aligned in their columns.
    @ViewBuilder
    private func figures(_ row: LimitsRow) -> some View {
        Text(row.share)
            .font(OMFont.numerals(size: LimitsLayout.rowShareSize, weight: .bold))
            .foregroundStyle(.om(.text))
            .lineLimit(1)
            .frame(width: LimitsLayout.shareWidth, alignment: .trailing)
        Text(row.dollars)
            .font(OMFont.numerals(size: LimitsLayout.rowDollarsSize, weight: .semibold))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
            .frame(width: LimitsLayout.dollarsWidth, alignment: .trailing)
    }

    private func nameText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: LimitsLayout.rowTitleSize, weight: .semibold))
            .foregroundStyle(.om(.text))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: LimitsLayout.rowSubtitleSize))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var hairline: some View {
        Rectangle()
            .fill(.om(.hairline))
            .frame(height: LimitsLayout.hairlineHeight)
            .accessibilityHidden(true)
    }
}
