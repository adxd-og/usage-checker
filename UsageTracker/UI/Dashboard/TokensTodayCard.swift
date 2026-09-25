import SwiftUI

/// One kind's part of a Tokens today bar: its token count, or its dollars.
struct OverviewTokenShare: Equatable {
    let category: TokenCategory
    let value: Double
}

/// A bar segment laid out in points.
struct OverviewTokenSegment: Equatable {
    let category: TokenCategory
    let width: CGFloat
}

/// One column of the Tokens today legend.
struct OverviewTokenLegendItem: Equatable {
    let category: TokenCategory
    let tokens: String
    /// nil when the provider prices a turn as a whole.
    let cost: String?
    /// Output's thinking, when the log has it.
    let note: String?
}

/// "Tokens today" (liquid-glass spec § Screens, "Overview"; `Dashboard-Overview(-Light).dc.html`):
/// what today's tokens were and what they cost, as two stacked bars in the token colours
/// over a legend of each kind's count and dollars. Shown only for a provider whose CLI
/// writes a per-turn log, once that log has something from today: a bar of nothing says
/// less than no card.
///
/// The Cost bar and the dollars appear only when the provider prices per category. The
/// Grok CLI prices a turn as a whole, so its card is counts alone rather than four
/// invented dollar figures. The day's total is the CLI card's: a figure appears once per
/// screen (Principle 4).
struct TokensTodayCard: View {
    let breakdown: TokenBreakdown
    /// "Tokens by day ›": History, on its tokens chart.
    var onTokensByDay: () -> Void = {}
    /// The API-equivalent note, shown when the pointer rests on the Cost bar; the CLI card
    /// prints it.
    var costCaption: String? = nil

    // MARK: - Words

    nonisolated static let title = "Tokens today"
    nonisolated static let tokensRowLabel = "Tokens"
    nonisolated static let costRowLabel = "Cost"

    // MARK: - Metrics

    nonisolated static let verticalPadding: CGFloat = 24
    nonisolated static let horizontalPadding: CGFloat = 28
    nonisolated static let spacing: CGFloat = 20
    nonisolated static let titleSize: CGFloat = 15
    nonisolated static let headerTrailingSize: CGFloat = 12.5
    nonisolated static let headerTrailingSpacing: CGFloat = 16
    nonisolated static let barLabelWidth: CGFloat = 64
    nonisolated static let barLabelSize: CGFloat = 12
    nonisolated static let barColumnSpacing: CGFloat = 16
    nonisolated static let barRowSpacing: CGFloat = 12
    nonisolated static let barHeight: CGFloat = 14
    nonisolated static let barCorner: CGFloat = 7
    nonisolated static let segmentGap: CGFloat = 2
    nonisolated static let minimumSegment: CGFloat = 3
    nonisolated static let legendSpacing: CGFloat = 24
    nonisolated static let legendDot: CGFloat = 8
    nonisolated static let legendLabelSize: CGFloat = 12.5
    nonisolated static let legendFigureSize: CGFloat = 22
    nonisolated static let legendCostSize: CGFloat = 14
    nonisolated static let legendNoteSize: CGFloat = 11.5

    // MARK: - Rules

    /// "68% of context came from cache" — the one number here worth a sentence.
    /// nil when there was no input at all to have a share of.
    nonisolated static func cacheShareCaption(_ breakdown: TokenBreakdown) -> String? {
        guard let share = breakdown.cacheHitShare else { return nil }
        return "\(Int((share * 100).rounded()))% of context came from cache"
    }

    /// The Tokens bar: each kind's count, in `TokenCategory` order, empty kinds dropped.
    nonisolated static func tokenShares(_ breakdown: TokenBreakdown) -> [OverviewTokenShare] {
        TokenCategory.allCases.compactMap { category -> OverviewTokenShare? in
            let tokens = category.tokens(in: breakdown)
            return tokens > 0 ? OverviewTokenShare(category: category, value: Double(tokens)) : nil
        }
    }

    /// The Cost bar: each kind's dollars. nil for a provider that prices a turn as a whole,
    /// and when every kind cost nothing.
    nonisolated static func costShares(_ breakdown: TokenBreakdown) -> [OverviewTokenShare]? {
        guard breakdown.cost != nil else { return nil }
        let shares = TokenCategory.allCases.compactMap { category -> OverviewTokenShare? in
            guard let cost = category.cost(in: breakdown), cost > 0 else { return nil }
            return OverviewTokenShare(category: category, value: cost)
        }
        return shares.isEmpty ? nil : shares
    }

    /// The shares laid out in a bar `width` points wide with 2 pt gaps. Every kind gets
    /// 3 pt first and the rest is shared in proportion, so a 0.003 % input is still seen
    /// next to a 97 % cache read and the row never overflows; a bar too narrow for the
    /// minimums shrinks them, and one with no room past its gaps draws nothing.
    nonisolated static func segments(_ shares: [OverviewTokenShare], in width: CGFloat) -> [OverviewTokenSegment] {
        let shown = shares.filter { $0.value > 0 }
        let total = shown.reduce(0) { $0 + $1.value }
        let available = width - segmentGap * CGFloat(max(0, shown.count - 1))
        guard !shown.isEmpty, total > 0, available > 0 else {
            return shown.map { OverviewTokenSegment(category: $0.category, width: 0) }
        }
        let floorWidth = min(minimumSegment, available / CGFloat(shown.count))
        let remainder = available - floorWidth * CGFloat(shown.count)
        var used: CGFloat = 0
        return shown.enumerated().map { index, share in
            // The last takes exactly what is left: the shares are divisions and their
            // rounding must not add up to more bar than there is.
            let segmentWidth = index == shown.count - 1
                ? available - used
                : floorWidth + remainder * CGFloat(share.value / total)
            used += segmentWidth
            return OverviewTokenSegment(category: share.category, width: segmentWidth)
        }
    }

    /// "incl. 716.6k thinking" under Output. Thinking is a slice of output, never a fifth
    /// kind: giving it one would imply it adds to the total, which it does not.
    nonisolated static func thinkingNote(_ breakdown: TokenBreakdown) -> String? {
        breakdown.thinking > 0 ? "incl. \(TokenFormat.formatTokens(breakdown.thinking)) thinking" : nil
    }

    /// The legend: one column per kind with tokens, its count, its dollars when the
    /// provider prices per kind, and output's thinking.
    nonisolated static func legend(_ breakdown: TokenBreakdown, locale: Locale = .current) -> [OverviewTokenLegendItem] {
        TokenCategory.allCases.compactMap { category -> OverviewTokenLegendItem? in
            let tokens = category.tokens(in: breakdown)
            guard tokens > 0 else { return nil }
            return OverviewTokenLegendItem(
                category: category,
                tokens: TokenFormat.formatTokens(tokens),
                cost: category.cost(in: breakdown).map { OMCostTile.money($0, locale: locale) },
                note: category == .output ? thinkingNote(breakdown) : nil
            )
        }
    }

    // MARK: - View

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            header
            bars
            legendRow
        }
        .padding(.vertical, Self.verticalPadding)
        .padding(.horizontal, Self.horizontalPadding)
        .dashboardCard(padding: 0)
    }

    /// Title, the cache sentence and the link on one line; the sentence drops under the
    /// title when the card is too narrow for all three.
    private var header: some View {
        let caption = Self.cacheShareCaption(breakdown)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Self.headerTrailingSpacing) {
                titleText
                Spacer(minLength: 8)
                if let caption { captionText(caption) }
                tokensByDayLink
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: 8)
                    tokensByDayLink
                }
                if let caption { captionText(caption) }
            }
        }
    }

    private var titleText: some View {
        Text(Self.title)
            .font(.system(size: Self.titleSize, weight: .semibold))
            .foregroundStyle(.om(.text))
    }

    private func captionText(_ caption: String) -> some View {
        Text(caption)
            .font(.system(size: Self.headerTrailingSize))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
    }

    private var tokensByDayLink: some View {
        Button(OverviewLink.tokensByDay.title, action: onTokensByDay)
            .buttonStyle(.omLink)
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: Self.barRowSpacing) {
            HStack(spacing: Self.barColumnSpacing) {
                barLabel(Self.tokensRowLabel)
                OverviewTokenBar(shares: Self.tokenShares(breakdown))
            }
            if let costs = Self.costShares(breakdown) {
                HStack(spacing: Self.barColumnSpacing) {
                    barLabel(Self.costRowLabel)
                    OverviewTokenBar(shares: costs)
                        .help(costCaption ?? "")
                }
            }
        }
    }

    private func barLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.barLabelSize, weight: .semibold))
            .foregroundStyle(.om(.secondary))
            .frame(width: Self.barLabelWidth, alignment: .leading)
    }

    /// Four columns as the mockup lays them; two by two when the card is too narrow.
    private var legendRow: some View {
        let items = Self.legend(breakdown)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Self.legendSpacing) {
                ForEach(items, id: \.category) { item in
                    legendItem(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Self.legendSpacing, alignment: .topLeading),
                    GridItem(.flexible(), spacing: Self.legendSpacing, alignment: .topLeading),
                ],
                alignment: .leading,
                spacing: Self.legendSpacing
            ) {
                ForEach(items, id: \.category) { item in
                    legendItem(item)
                }
            }
        }
        .padding(.top, 4)
    }

    private func legendItem(_ item: OverviewTokenLegendItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(OMColor(item.category.token))
                    .frame(width: Self.legendDot, height: Self.legendDot)
                legendLabel(item.category)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.tokens)
                    .font(OMFont.numerals(size: Self.legendFigureSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                if let cost = item.cost {
                    Text(cost)
                        .font(OMFont.numerals(size: Self.legendCostSize, weight: .semibold))
                        .foregroundStyle(.om(.secondary))
                }
            }
            if let note = item.note {
                Text(note)
                    .font(.system(size: Self.legendNoteSize))
                    .foregroundStyle(.om(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Input" is the label the CLIs use; what it counts is the uncached part of the
    /// context, and only a tooltip has room to say so.
    @ViewBuilder
    private func legendLabel(_ category: TokenCategory) -> some View {
        let label = Text(category.label)
            .font(.system(size: Self.legendLabelSize, weight: .semibold))
            .foregroundStyle(.om(.secondary))
        if let help = category.help {
            label.help(help)
        } else {
            label
        }
    }
}

/// One stacked bar of the Tokens today card: the shares as segments with 2 pt gaps,
/// clipped to a 7 pt corner. VoiceOver skips it: the legend says the same in words.
private struct OverviewTokenBar: View {
    let shares: [OverviewTokenShare]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: TokensTodayCard.segmentGap) {
                ForEach(TokensTodayCard.segments(shares, in: geometry.size.width), id: \.category) { segment in
                    Rectangle()
                        .fill(OMColor(segment.category.token))
                        .frame(width: segment.width)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TokensTodayCard.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: TokensTodayCard.barCorner, style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview("Tokens today") {
    TokensTodayCard(
        breakdown: TokenBreakdown(
            input: 21_100, output: 2_100_000, cacheRead: 802_100_000,
            cacheWrite5m: 20_000_000, cacheWrite1h: 0, thinking: 716_600,
            cost: TokenCostBreakdown(input: 0.16, output: 63.40, cacheRead: 304.77, cacheWrite: 174.53)
        )
    )
    .padding()
    .frame(width: 974)
}
