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
