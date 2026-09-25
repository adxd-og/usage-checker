import SwiftUI

/// The Agents tab's stats card (`Dashboard-Agents(-Light).dc.html`): a row of three
/// equal columns, each a 12.5 pt label over a 26 pt rounded figure, with a hairline
/// before every column after the first that holds a tile. What goes in which column is
/// `AgentsStatsRules`; in 3.0 only the first is filled, and the empty two keep the
/// mockup's proportions.
struct AgentsStatsCard: View {
    let tiles: [AgentsStatTile]

    var body: some View {
        HStack(alignment: .top, spacing: AgentsLayout.statColumnGap) {
            ForEach(AgentsStatsRules.cells(tiles)) { cell in
                column(cell)
            }
        }
        .padding(.vertical, AgentsLayout.cardVerticalPadding)
        .padding(.horizontal, AgentsLayout.cardHorizontalPadding)
        .dashboardCard(padding: 0)
    }

    @ViewBuilder
    private func column(_ cell: AgentsStatCell) -> some View {
        if let tile = cell.tile {
            figure(tile)
                .padding(.leading, cell.leadingDivider ? AgentsLayout.statColumnGap : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if cell.leadingDivider {
                        Rectangle()
                            .fill(.om(.hairline))
                            .frame(width: 1)
                            .accessibilityHidden(true)
                    }
                }
        } else {
            // An empty column still takes its third of the row.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .accessibilityHidden(true)
        }
    }

    private func figure(_ tile: AgentsStatTile) -> some View {
        VStack(alignment: .leading, spacing: AgentsLayout.statLabelValueSpacing) {
            Text(tile.label)
                .font(.system(size: AgentsLayout.statLabelSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
            Text(tile.value)
                .font(OMFont.numerals(size: AgentsLayout.statValueSize, weight: .bold))
                .tracking(AgentsLayout.statValueTracking)
                .foregroundStyle(.om(.text))
                .lineLimit(1)
        }
        // One stop per tile: "Sessions, 31".
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Agents stats — light") {
    AgentsStatsCard(tiles: [AgentsStatTile(label: "Sessions", value: "31")])
        .padding()
        .frame(width: 900)
}

#Preview("Agents stats — dark") {
    AgentsStatsCard(tiles: [AgentsStatTile(label: "Sessions", value: "31")])
        .padding()
        .frame(width: 900)
        .preferredColorScheme(.dark)
}
#endif
