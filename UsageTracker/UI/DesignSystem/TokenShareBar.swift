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

    /// The segments laid out in a bar `width` points wide, in display order.
    ///
    /// Every visible bucket is allocated `minimum` first and the rest is shared in
    /// proportion, so the row can never be wider than the bar. Applying the minimum
    /// to each segment independently — `max(2, width * share)` — is an overdraft:
    /// counts of [1, 1, 9997, 1] in a 300-pt bar asked for 305.9 pt and the last
    /// segment was simply clipped off the end. A bar too narrow to give every bucket
    /// its minimum shrinks the minimum rather than overflowing.
    nonisolated static func widths(
        _ breakdown: TokenBreakdown, in width: CGFloat, minimum: CGFloat = 2
    ) -> [(TokenCategory, CGFloat)] {
        let shares = segments(breakdown)
        guard !shares.isEmpty, width > 0 else { return shares.map { ($0.0, 0) } }
        let floorWidth = min(minimum, width / CGFloat(shares.count))
        let remainder = width - floorWidth * CGFloat(shares.count)
        var result: [(TokenCategory, CGFloat)] = []
        var used: CGFloat = 0
        for (i, share) in shares.enumerated() {
            // The last one takes exactly what is left: the shares are divisions of
            // Ints and their rounding must not add up to more bar than there is.
            let w = i == shares.count - 1
                ? width - used
                : floorWidth + remainder * CGFloat(share.1)
            result.append((share.0, w))
            used += w
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let segments = Self.widths(breakdown, in: geo.size.width)
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].0.color)
                        .frame(width: segments[i].1)
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
