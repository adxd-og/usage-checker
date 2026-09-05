import SwiftUI

/// "Tokens today" — what today's tokens *were*, not just how many of them there
/// were. Shown only for a provider whose CLI writes a per-turn log, and only once
/// that log has something from today: a bar of nothing says less than no card.
///
/// The dollar column appears only when the provider prices per category. The Grok
/// CLI prices a turn as a whole, so its rows are counts alone rather than four
/// invented dollar figures.
struct TokensTodayCard: View {
    let breakdown: TokenBreakdown

    /// "68% of context came from cache" — the one number here worth a sentence.
    /// nil when there was no input at all to have a share of.
    nonisolated static func cacheShareCaption(_ breakdown: TokenBreakdown) -> String? {
        guard let share = breakdown.cacheHitShare else { return nil }
        return "\(Int((share * 100).rounded()))% of context came from cache"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            OMSectionHeader(
                title: "Tokens today",
                trailing: "\(TokenFormat.formatTokens(breakdown.total)) tokens"
            )
            TokenShareBar(breakdown: breakdown)
            VStack(alignment: .leading, spacing: OMSpacing.s) {
                ForEach(TokenCategory.allCases) { category in
                    let tokens = category.tokens(in: breakdown)
                    if tokens > 0 {
                        row(category, tokens: tokens)
                    }
                }
            }
            if let caption = Self.cacheShareCaption(breakdown) {
                Text(caption)
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .dashboardCard()
    }

    @ViewBuilder
    private func row(_ category: TokenCategory, tokens: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: OMSpacing.s) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(category.color)
                    .frame(width: 10, height: 10)
                Text(category.label).font(OMFont.bodyStrong)
                Spacer()
                Text(TokenFormat.formatTokens(tokens))
                    .font(OMFont.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                if let cost = category.cost(in: breakdown) {
                    Text(String(format: "$%.2f", cost))
                        .font(OMFont.body)
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }
            // Thinking is a slice of output, never a fifth row: giving it one
            // would imply it adds to the total, which it does not.
            if category == .output, breakdown.thinking > 0 {
                Text("of which thinking \(TokenFormat.formatTokens(breakdown.thinking))")
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 18)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Tokens today") {
    TokensTodayCard(
        breakdown: TokenBreakdown(
            input: 120_000, output: 41_000, cacheRead: 2_400_000,
            cacheWrite5m: 180_000, cacheWrite1h: 0, thinking: 9_400,
            cost: TokenCostBreakdown(input: 0.36, output: 0.62, cacheRead: 0.72, cacheWrite: 0.68)
        )
    )
    .padding()
    .frame(width: 420)
}
