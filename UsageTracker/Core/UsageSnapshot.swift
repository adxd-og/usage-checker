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

    var clampedPercent: Double { max(0, min(100, utilization)) }

    /// Total length of this rate-limit window, inferred from its id/kind.
    /// nil when the length can't be inferred (unknown future window types).
    var windowDuration: TimeInterval? {
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

    var headlinePercent: Double {
        buckets.map(\.clampedPercent).max() ?? 0
    }
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
        services.flatMap(\.buckets).map(\.clampedPercent).max() ?? 0
    }

    var hasAnyData: Bool {
        services.contains(where: { !$0.buckets.isEmpty })
    }
}
