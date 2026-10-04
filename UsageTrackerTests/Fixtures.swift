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
        windowLength: TimeInterval? = nil,
        credit: CreditPool? = nil
    ) -> UsageBucket {
        UsageBucket(
            id: id,
            label: label,
            utilization: percent,
            resetsAt: resetsAt,
            kind: kind,
            windowLength: windowLength,
            credit: credit
        )
    }

    /// `/api/oauth/usage` as this account returned it on 2026-10-04: the plan's windows
    /// in `limits` and as legacy keys, and `iguana_necktie` — claude.ai's "Cloud session
    /// credits", $19 of $250 left, expiring November 5 — copied verbatim. `limits` does
    /// not carry the pool. Its dollars are WHOLE dollars, unlike `extra_usage`, which is
    /// in cents.
    static let cloudCreditsPayload = """
    {
      "five_hour": { "utilization": 7.0, "resets_at": "2026-10-04T12:49:59+00:00" },
      "seven_day": { "utilization": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" },
      "iguana_necktie": {"utilization": 92.368272, "resets_at": "2026-11-05T07:59:00+00:00", "limit_dollars": 250, "used_dollars": 230.92068, "remaining_dollars": 19.08, "locked_reason": null},
      "limits": [
        { "kind": "session", "group": "session", "percent": 7.0, "resets_at": "2026-10-04T12:49:59+00:00" },
        { "kind": "weekly_all", "group": "weekly", "percent": 69.0, "resets_at": "2026-10-08T09:59:59+00:00" }
      ]
    }
    """

    /// The bucket `cloudCreditsPayload`'s pool becomes: 92 % spent, $230.92 of $250,
    /// expiring 2026-11-05 07:59 UTC.
    static let cloudCredits = Fixture.bucket(
        id: "iguana_necktie",
        label: "Cloud session credits",
        percent: 92.368272,
        resetsAt: Date(timeIntervalSince1970: 1_793_865_540),
        kind: .other,
        credit: CreditPool(usedDollars: 230.92068, limitDollars: 250)
    )

    static func snapshot(
        id: String = "claude",
        displayName: String? = nil,
        icon: String = "sparkles",
        plan: String? = "Max 20x",
        accountLabel: String? = nil,
        buckets: [UsageBucket] = [],
        extraUsage: ExtraUsage? = nil,
        weekCost: Double? = nil,
        state: ServiceState = .ok,
        stateMessage: String? = nil,
        at date: Date = Date()
    ) -> ServiceSnapshot {
        ServiceSnapshot(
            id: id,
            displayName: displayName ?? id.capitalized,
            icon: icon,
            plan: plan,
            accountLabel: accountLabel,
            buckets: buckets,
            extraUsage: extraUsage,
            weekCost: weekCost,
            state: state,
            stateMessage: stateMessage,
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
