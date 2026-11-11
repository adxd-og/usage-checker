import Foundation

/// One `_budget` entry of `GET /v1/billing/budget` (spec 2026-11-10 § Facts), as
/// `MistralBillingFetcher` decodes it: the top-level key it came under and its figures.
struct MistralBudgetEntry: Equatable, Sendable {
    /// `vibe_budget`, `api_budget`, or any other top-level key ending in `_budget`.
    let key: String
    /// 0–100, fractional, as Mistral counts it; it may go past 100 once pay-as-you-go spends
    /// beyond the allowance (not verified, spec § Facts).
    let usagePercentage: Double
    /// The allowance, in `currency`; nil when the entry gives none or not as a number.
    var initialBudget: Double? = nil
    var currency: String? = nil
    /// When the allowance starts over; nil when absent or not ISO 8601.
    var resetAt: Date? = nil
}

/// Mistral's `/budget` entries as windows (spec 2026-11-10 § Windows): one bucket per `_budget`
/// key, decoded dynamically, with no table of windows. Vibe first, the long window as Codex's
/// Monthly; API beside it, model-scoped; any other key after them, model-scoped. Pure.
enum MistralBudgetRules {
    static let keySuffix = "_budget"
    static let vibeKey = "vibe_budget"
    static let apiKey = "api_budget"

    /// "vibe_budget" → "vibe"; nil for a key that is no budget or names nothing. The key is the
    /// server's choice and its name becomes a label and an id: its control characters go, and
    /// a name of nothing else names nothing.
    static func name(forKey key: String) -> String? {
        guard key.hasSuffix(keySuffix) else { return nil }
        let name = MistralCopy.withoutControlCharacters(String(key.dropLast(keySuffix.count)))
        return name.isEmpty ? nil : name
    }

    static func bucketID(forKey key: String) -> String {
        "mistral_" + (name(forKey: key) ?? MistralCopy.withoutControlCharacters(key))
    }

    /// "Vibe", "API", any other name capitalised word by word ("team_seats" → "Team Seats").
    static func label(forKey key: String) -> String {
        switch key {
        case vibeKey: return MistralCopy.vibeLabel
        case apiKey: return MistralCopy.apiLabel
        default:
            return (name(forKey: key) ?? MistralCopy.withoutControlCharacters(key))
                .replacingOccurrences(of: "_", with: " ").lowercased().capitalized
        }
    }

    /// Vibe is the plan's own allowance and leads the headline; the others never do.
    static func kind(forKey key: String) -> BucketKind {
        key == vibeKey ? .weekly : .modelSpecific
    }

    /// Vibe, API, then the rest by key: the decoder keeps no JSON order.
    static func ordered(_ entries: [MistralBudgetEntry]) -> [MistralBudgetEntry] {
        func rank(_ key: String) -> Int { key == vibeKey ? 0 : (key == apiKey ? 1 : 2) }
        return entries.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
    }

    /// The allowance runs the calendar month (UTC) before its reset: 30 days to 1 December,
    /// 28 to 1 March. Stated so pace and the Limits tab do not take the seven days `.weekly`
    /// infers. nil without a reset.
    static func windowLength(resetsAt: Date?) -> TimeInterval? {
        guard let resetsAt else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let start = utc.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
        return resetsAt.timeIntervalSince(start)
    }

    /// "$17.88 of $300": Mistral's own count, used = initial_budget × usage_percentage / 100.
    /// nil without a positive allowance, or in a currency other than US dollars: no `$` in
    /// front of another currency's figure. nil too when the allowance or the used dollars are
    /// no finite number (1e308 × 1e308): the window then shows without dollars.
    static func allowance(_ entry: MistralBudgetEntry) -> CreditPool? {
        guard let budget = entry.initialBudget, budget.isFinite, budget > 0,
              entry.currency?.uppercased() == "USD"
        else { return nil }
        let used = budget * max(0, entry.usagePercentage) / 100
        guard used.isFinite else { return nil }
        return CreditPool(usedDollars: used, limitDollars: budget)
    }

    static func bucket(from entry: MistralBudgetEntry) -> UsageBucket {
        UsageBucket(
            id: bucketID(forKey: entry.key),
            label: label(forKey: entry.key),
            utilization: min(100, max(0, entry.usagePercentage)),
            resetsAt: entry.resetAt ?? .distantFuture,
            kind: kind(forKey: entry.key),
            windowLength: windowLength(resetsAt: entry.resetAt),
            allowance: allowance(entry)
        )
    }

    /// Every entry under a `_budget` key, in order.
    static func buckets(from entries: [MistralBudgetEntry]) -> [UsageBucket] {
        ordered(entries.filter { name(forKey: $0.key) != nil }).map(bucket(from:))
    }
}
