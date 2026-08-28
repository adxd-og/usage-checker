import Foundation
@testable import Omelette

/// Builders for the value types production code takes. The app deliberately has no
/// test-only initializers, so every fixture here is a real `ServiceSnapshot` /
/// `UsageBucket` — the same objects a provider would hand the rest of the app.
enum Fixture {
    static func bucket(
        id: String,
        label: String = "Window",
        percent: Double = 0,
        resetsAt: Date = .distantFuture,
        kind: BucketKind = .other,
        windowLength: TimeInterval? = nil
    ) -> UsageBucket {
        UsageBucket(
            id: id,
            label: label,
            utilization: percent,
            resetsAt: resetsAt,
            kind: kind,
            windowLength: windowLength
        )
    }

    static func snapshot(
        id: String = "claude",
        displayName: String? = nil,
        plan: String? = "Max 20x",
        buckets: [UsageBucket] = [],
        extraUsage: ExtraUsage? = nil,
        weekCost: Double? = nil,
        state: ServiceState = .ok,
        at date: Date = Date()
    ) -> ServiceSnapshot {
        ServiceSnapshot(
            id: id,
            displayName: displayName ?? id.capitalized,
            icon: "sparkles",
            plan: plan,
            accountLabel: nil,
            buckets: buckets,
            extraUsage: extraUsage,
            weekCost: weekCost,
            state: state,
            stateMessage: nil,
            fetchedAt: date
        )
    }

    /// History points for a single bucket, given as (minutes before `now`, percent).
    /// Order is free: `Analytics.burnRate` sorts by timestamp before reading the ends.
    static func history(
        service: String = "claude",
        bucketID: String,
        points: [(minutesAgo: Double, percent: Double)],
        now: Date = Date()
    ) -> [HistoryRecord] {
        points.map { point in
            HistoryRecord(
                from: snapshot(id: service, buckets: [bucket(id: bucketID, percent: point.percent)]),
                at: now.addingTimeInterval(-point.minutesAgo * 60)
            )
        }
    }

    /// History points carrying several windows at once, at absolute times. `history`
    /// above is enough for burn rate, which reads one bucket relative to now; quota
    /// charts read every bucket of a record and bin by calendar day, so they need both
    /// halves fixed.
    static func quotaHistory(
        service: String = "antigravity",
        points: [(at: Date, percents: [String: Double])]
    ) -> [HistoryRecord] {
        points.map { point in
            HistoryRecord(
                from: snapshot(
                    id: service,
                    buckets: point.percents
                        .sorted { $0.key < $1.key }
                        .map { bucket(id: $0.key, percent: $0.value) }
                ),
                at: point.at
            )
        }
    }

    static func prediction(
        secondsToLimit: TimeInterval?,
        percentPerMinute: Double = 1,
        bucketId: String = "five_hour",
        isStale: Bool = false
    ) -> BurnRatePrediction {
        BurnRatePrediction(
            secondsToLimit: secondsToLimit,
            percentPerMinute: percentPerMinute,
            bucketId: bucketId,
            isStale: isStale
        )
    }
}
