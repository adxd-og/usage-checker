import SwiftUI

/// One rounded capsule split into the token buckets, in `TokenCategory` order.
/// Empty buckets are dropped rather than drawn as invisible slivers, and a
/// non-empty one is never thinner than 2 pt — a 0.3% cache write is still a fact
/// worth seeing next to a 90% cache read.
///
/// The bar itself is hidden from VoiceOver: the rows underneath say the same
/// thing in words, and a run of unlabelled rectangles adds nothing.
struct TokenShareBar: View {
    let breakdown: TokenBreakdown
    var height: CGFloat = 10

    /// Which segments to draw, as (category, share of the total) in display
    /// order. Empty when there are no tokens at all — callers hide the card.
    nonisolated static func segments(_ breakdown: TokenBreakdown) -> [(TokenCategory, Double)] {
        let total = breakdown.total
        guard total > 0 else { return [] }
        return TokenCategory.allCases.compactMap { category in
            let tokens = category.tokens(in: breakdown)
            guard tokens > 0 else { return nil }
            return (category, Double(tokens) / Double(total))
        }
    }

    var body: some View {
        let segments = Self.segments(breakdown)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].0.color)
                        .frame(width: max(2, geo.size.width * segments[i].1))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

#Preview("Token share") {
    TokenShareBar(
        breakdown: TokenBreakdown(input: 120_000, output: 40_000, cacheRead: 2_400_000, cacheWrite5m: 180_000)
    )
    .padding()
    .frame(width: 328)
}
