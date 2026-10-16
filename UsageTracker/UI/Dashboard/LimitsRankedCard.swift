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
    /// In place of the rows when the window has none.
    let emptyText: String
    let isWide: Bool

    @State private var showsAll = false
    /// The rows on screen, formatted; nil until the first build.
    @State private var ranked: LimitsRankedRows?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, LimitsLayout.rankedHeaderBottom)
            if let ranked {
                rowsSection(ranked)
            }
        }
        .padding(LimitsLayout.rankedCardPadding)
        .dashboardCard(padding: 0)
        .task(id: rowsKey) {
            ranked = LimitsRules.chatRows(of: load.share, serviceID: load.serviceID, showsAll: showsAll)
        }
    }

    /// What the rows are built from: the load (what it answered, and the share itself, so a re-cut of an expired window with the same query still rebuilds) and
    /// the cap.
    private struct RowsKey: Equatable {
        let query: LimitsQuery
        let share: LimitShare
        let showsAll: Bool
    }

    private var rowsKey: RowsKey {
        RowsKey(query: load.query, share: load.share, showsAll: showsAll)
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
                rankedRow(row)
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

    /// The title with its caption on one baseline.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LimitsLayout.titleSpacing) {
            titleBlock
            Spacer(minLength: 0)
        }
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
