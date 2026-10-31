import Foundation

/// The reading the pet and the ears alarm for (notch-island spec 2026-10-29 § 3.5 "Alert
/// selector", § 3.6): one window of one provider, at 90 % used or more.
struct PetAlert: Equatable, Sendable {
    let serviceID: String
    /// The provider's name as its tile shows it ("Claude").
    let serviceName: String
    let bucket: UsageBucket

    /// The used percent, 0…100: what the ear and the mood line print through `PercentDisplay`.
    var usedPercent: Double { bucket.clampedPercent }
}

/// Which reading the pet alarms for (notch-island spec 2026-10-29 § 3.5, § 3.9
/// `PetAlertSelector`). Eligible: the live windows of enabled providers (never a retained or
/// failed one), except prepaid credit pools and promotional pools, and except model-scoped
/// windows, as in `UsageNotifier.watchableBuckets` and `headlinePercent`: a saturated "Fable only"
/// is not the limit, and can sit at 100 % for days with nothing to act on (ruling R2, which narrows
/// § 3.5). Unless scoping is all a provider has: then its per-model windows are its
/// limits. A self-set budget (`AppState.payAsYouGoBudgetBucketID`) counts. It fires at 90 % used; the
/// highest used percent wins, ties going to the provider shown first, then to the shorter
/// window, then to the provider's own order. It is not the tile's hero: a 92 % week wins over
/// the 40 % session the tile leads with. Pure.
enum PetAlertSelector {
    /// Used percent at which a window alarms (≥ 90.0).
    static let threshold: Double = 90

    /// The alert among `services` (the snapshot's, in display order), or nil. `enabledIDs` is
    /// the set switched on this moment (`AppState.switchedOnIDs`); nil, before the first poll,
    /// limits nothing.
    static func alert(in services: [ServiceSnapshot], enabledIDs: Set<String>?) -> PetAlert? {
        var best: (alert: PetAlert, rank: Rank)?
        for (order, service) in services.enumerated() where service.state == .ok {
            if let enabledIDs, !enabledIDs.contains(service.id) { continue }
            let hasCoreWindow = service.buckets.contains { !$0.isBonusPool && $0.kind != .modelSpecific }
            for (index, bucket) in service.buckets.enumerated()
            where !bucket.isBonusPool && bucket.clampedPercent >= threshold && (!hasCoreWindow || bucket.kind != .modelSpecific) {
                let rank = Rank(
                    percent: bucket.clampedPercent,
                    order: order,
                    length: bucket.windowDuration ?? .infinity,
                    index: index
                )
                if best.map({ rank.beats($0.rank) }) ?? true {
                    best = (PetAlert(serviceID: service.id, serviceName: service.displayName, bucket: bucket), rank)
                }
            }
        }
        return best?.alert
    }

    /// How a candidate ranks: more used, then the provider shown first, then the shorter
    /// window (unknown length counts as longest), then the provider's own order.
    private struct Rank {
        let percent: Double
        let order: Int
        let length: TimeInterval
        let index: Int

        func beats(_ other: Rank) -> Bool {
            if percent != other.percent { return percent > other.percent }
            if order != other.order { return order < other.order }
            if length != other.length { return length < other.length }
            return index < other.index
        }
    }
}
