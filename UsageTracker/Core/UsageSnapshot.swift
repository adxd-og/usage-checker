import Foundation

enum BucketKind: String, Sendable, Codable {
    case session
    case weekly
    case modelSpecific
    case other
}

struct UsageBucket: Equatable, Sendable, Identifiable, Codable {
    let id: String
    let label: String
    let utilization: Double
    let resetsAt: Date
    let kind: BucketKind
    /// Total length of the window when the provider states it (CodexBarCore's
    /// `RateWindow.windowMinutes`). Optional with a nil default so records
    /// persisted by older builds still decode, and so the inference below
    /// remains the fallback for providers that report no length.
    var windowLength: TimeInterval? = nil

    var clampedPercent: Double { max(0, min(100, utilization)) }

    /// Bonus quota pools (e.g. Anthropic's "…_promotional" windows). Informational:
    /// running one dry costs nothing, so they never drive the headline percent,
    /// the hero header, or threshold notifications — only their own row.
    var isPromotional: Bool {
        id.lowercased().contains("promo") || label.lowercased().contains("promo")
    }

    /// Total length of this rate-limit window. The provider's own figure wins;
    /// the id/kind inference is a fallback for Anthropic's windows, which the
    /// usage API never states a length for. Inferring alone made every
    /// model-scoped window a week — wrong for Gemini, whose per-model quotas
    /// are daily, so its pace indicator read as barely-started all day.
    /// nil when the length is neither reported nor inferable.
    var windowDuration: TimeInterval? {
        if let windowLength, windowLength > 0 { return windowLength }
        if id == "five_hour" || kind == .session { return 5 * 3600 }
        if id.hasPrefix("seven_day") || kind == .weekly || kind == .modelSpecific { return 7 * 24 * 3600 }
        return nil
    }

    /// Fraction of the window already elapsed (0...1), derived from resetsAt.
    /// Lets the UI show usage against "even pace": 60% used at 90% elapsed is fine,
    /// 60% used at 20% elapsed is trouble. nil when reset time or length is unknown,
    /// or when the remaining time exceeds the inferred length (inference was wrong).
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard resetsAt < .distantFuture, let duration = windowDuration else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        return 1 - remaining / duration
    }
}

struct ExtraUsage: Equatable, Sendable, Codable {
    let isEnabled: Bool
    let monthlyLimit: Double
    let usedCredits: Double
    let utilization: Double
}

enum ServiceState: String, Sendable, Codable {
    case ok
    case notSignedIn
    case notRunning
    case error
}

struct ServiceSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let icon: String
    let plan: String?
    let accountLabel: String?
    let buckets: [UsageBucket]
    let extraUsage: ExtraUsage?
    let weekCost: Double?
    let state: ServiceState
    let stateMessage: String?
    let fetchedAt: Date
    /// After a 429, how many seconds to wait before polling again. nil = no backoff.
    var retryAfter: TimeInterval? = nil

    /// The number the menu bar shows: the worst *core* constraint. Promotional
    /// pools don't count (free bonuses shouldn't scream "almost at the limit"),
    /// and model-scoped windows (an "Opus only" / "Fable only" cap) inform their
    /// own row without driving the headline — the all-models weekly is "the"
    /// limit. An Enterprise spend limit does count. Scoped/promo windows only
    /// lead when they're all the account has.
    var headlinePercent: Double {
        var candidates = buckets
            .filter { !$0.isPromotional && $0.kind != .modelSpecific }
            .map(\.clampedPercent)
        if let extra = extraUsage, extra.isEnabled {
            candidates.append(max(0, min(100, extra.utilization)))
        }
        if candidates.isEmpty {
            candidates = buckets.filter { !$0.isPromotional }.map(\.clampedPercent)
        }
        if candidates.isEmpty {
            candidates = buckets.map(\.clampedPercent)
        }
        return candidates.max() ?? 0
    }

    /// The service failed but still has numbers on screen: this session's previous
    /// poll — or, after a relaunch, `LastKnownStore` — kept the last good reading.
    /// One predicate for every surface that draws a service, so the tile, the
    /// popover rows, the dashboard and the menu bar can't disagree about it.
    var isRetained: Bool { state != .ok && !buckets.isEmpty }

    /// When the retained numbers were last true. nil for a live service — it has
    /// nothing to stamp.
    var retainedAt: Date? { isRetained ? fetchedAt : nil }
}

/// Enterprise/Team accounts know extra usage as their spend limit;
/// subscription accounts as prepaid extra credits. Same API field either way.
func extraUsageTitle(plan: String?) -> String {
    let plan = plan ?? ""
    return plan.contains("Enterprise") || plan.contains("Team") ? "Spend limit" : "Extra usage credits"
}

struct UsageSnapshot: Equatable, Sendable {
    let services: [ServiceSnapshot]
    let fetchedAt: Date
    let isStale: Bool
    let lastError: String?

    static let empty = UsageSnapshot(
        services: [],
        fetchedAt: Date(timeIntervalSince1970: 0),
        isStale: true,
        lastError: nil
    )

    var headlinePercent: Double {
        services.map(\.headlinePercent).max() ?? 0
    }

    var hasAnyData: Bool {
        services.contains(where: { !$0.buckets.isEmpty })
    }
}
