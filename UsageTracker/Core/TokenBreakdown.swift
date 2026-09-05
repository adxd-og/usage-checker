import Foundation

/// Tokens of one turn, day, model or window split by what they were.
///
/// `input` is always the *fresh* (uncached) input, whatever the provider's raw counter
/// means, so the five buckets are disjoint and `total` is their sum. `thinking` is a
/// subset of `output` and is not part of `total`.
struct TokenBreakdown: Sendable, Codable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite5m: Int = 0
    var cacheWrite1h: Int = 0
    /// Subset of `output`. 0 when the log has no figure (older Claude logs, Grok).
    var thinking: Int = 0

    /// Dollars per bucket, same keys. nil when the provider prices a turn as a whole
    /// (Grok's `costUsdTicks`) and no per-category split is known.
    var cost: TokenCostBreakdown? = nil

    static let zero = TokenBreakdown()

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    var total: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    /// Context tokens that came from cache, as a share of all input-side tokens (input +
    /// cacheRead + cacheWrite). nil when there is no input at all.
    var cacheHitShare: Double? {
        let contextTokens = input + cacheRead + cacheWrite
        guard contextTokens > 0 else { return nil }
        return Double(cacheRead) / Double(contextTokens)
    }

    /// A copy with `cost` filled from the model's rates — the same arithmetic
    /// `CLITurn.cost` runs, kept bucket by bucket so the UI can show where the money
    /// went.
    func priced(model: String) -> TokenBreakdown {
        priced(with: ModelPricing.price(for: model))
    }

    /// The same, for a caller that has already looked the rates up: Codex prices from
    /// `ModelPricing.dynamicLookup(for:)`, which can answer nil, and decides for itself
    /// what an unpriced model means. The two TTLs are priced apart and reported
    /// together, because the UI has one "cache write" dollar column.
    func priced(with price: ModelPrice) -> TokenBreakdown {
        var copy = self
        copy.cost = TokenCostBreakdown(
            input: Double(input) * price.inputPerM / 1_000_000,
            output: Double(output) * price.outputPerM / 1_000_000,
            cacheRead: Double(cacheRead) * price.cacheReadPerM / 1_000_000,
            cacheWrite: (Double(cacheWrite5m) * price.cacheCreate5mPerM
                + Double(cacheWrite1h) * price.cacheCreate1hPerM) / 1_000_000
        )
        return copy
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        var sum = TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            thinking: lhs.thinking + rhs.thinking
        )
        if let l = lhs.cost, let r = rhs.cost {
            sum.cost = l + r
        } else if lhs == .zero {
            // `zero` is the identity, dollars included. Every accumulator in the
            // aggregators starts there, and a summand that carries nothing at all must
            // not turn a priced total into an unpriced one.
            sum.cost = rhs.cost
        } else if rhs == .zero {
            sum.cost = lhs.cost
        }
        // Otherwise one side really is a provider without a per-category split, and the
        // honest answer for the sum is "unknown".
        return sum
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

/// Dollars per bucket. `cacheWrite` is the two TTLs together — the UI has one column.
struct TokenCostBreakdown: Sendable, Codable, Equatable {
    var input: Double = 0
    var output: Double = 0
    var cacheRead: Double = 0
    var cacheWrite: Double = 0

    var total: Double { input + output + cacheRead + cacheWrite }

    static func + (lhs: Self, rhs: Self) -> Self {
        TokenCostBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// One row of the UI's breakdown list / one segment of the bar, in display order.
///
/// The colour is deliberately not here: Core carries no SwiftUI dependency, so the
/// dashboard target adds `TokenCategory.color` in its own extension.
enum TokenCategory: String, CaseIterable, Identifiable, Sendable {
    case input, output, cacheRead, cacheWrite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .input: return "Input"
        case .output: return "Output"
        case .cacheRead: return "Cache read"
        case .cacheWrite: return "Cache write"
        }
    }

    func tokens(in b: TokenBreakdown) -> Int {
        switch self {
        case .input: return b.input
        case .output: return b.output
        case .cacheRead: return b.cacheRead
        case .cacheWrite: return b.cacheWrite
        }
    }

    /// nil for a provider that prices a turn as a whole — the row shows tokens only.
    func cost(in b: TokenBreakdown) -> Double? {
        guard let c = b.cost else { return nil }
        switch self {
        case .input: return c.input
        case .output: return c.output
        case .cacheRead: return c.cacheRead
        case .cacheWrite: return c.cacheWrite
        }
    }
}

/// Token counts as the UI prints them ("999", "12.3k", "1.5M"). One implementation,
/// because two views had drifted copies of it.
enum TokenFormat {
    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
