import Foundation

/// A span a limit share is cut for: one limit window, or one spend period.
struct LimitWindow: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// What each chat cost in limit percent, and what a percent costs: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design. Pure: the dashboard
/// passes in the account's snapshot, the window's percent readings and the turns its
/// cost log holds, and the Limits tab shows the result.
enum LimitShareRules {
    /// The account's window of `kind`: its first bucket of that kind that is a real
    /// limit. These are not limits:
    /// - a bonus or credit pool;
    /// - the weekly budget Omelette invents for a pay-as-you-go account
    ///   (`CostCopy.syntheticBucketIDs`, kind `.weekly`).
    ///
    /// Only `.session` and `.weekly` count; model-specific windows are out of scope.
    /// The bucket is picked by kind, never by id: Codex names its first lane
    /// `codex_session` whatever its length, and on Prolite that lane is the week.
    nonisolated static func coreBucket(kind: BucketKind, in service: ServiceSnapshot) -> UsageBucket? {
        guard kind == .session || kind == .weekly else { return nil }
        return service.buckets.first {
            $0.kind == kind && !$0.isBonusPool && !CostCopy.syntheticBucketIDs.contains($0.id)
        }
    }

    /// The windows the window switch offers, Session before Week, and only those the
    /// account has. Codex Prolite has the Week alone.
    nonisolated static func windowKinds(of service: ServiceSnapshot) -> [BucketKind] {
        [BucketKind.session, .weekly].filter { coreBucket(kind: $0, in: service) != nil }
    }

    /// The window open now: `resetsAt − windowDuration` to now. If the reading is older
    /// than the reset (a retained snapshot), the window ends at the reset instead. nil
    /// when the bucket names no reset or no length, or the window has not started.
    nonisolated static func currentWindow(of bucket: UsageBucket, now: Date) -> LimitWindow? {
        guard bucket.resetsAt < .distantFuture, let duration = bucket.windowDuration else { return nil }
        let start = bucket.resetsAt.addingTimeInterval(-duration)
        let end = min(now, bucket.resetsAt)
        guard start < end else { return nil }
        return LimitWindow(start: start, end: end)
    }
}
