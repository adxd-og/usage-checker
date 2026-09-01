import Foundation

/// Answers the question the burn rate is actually for: will I hit the limit
/// before the window resets, or can I keep going at this pace?
struct BurnVerdict: Equatable {
    let willHit: Bool
    let text: String

    static func make(burn: BurnRatePrediction?, sessionBuckets: [UsageBucket], now: Date = Date()) -> BurnVerdict? {
        guard let burn, !burn.isStale,
              let secs = burn.secondsToLimit,
              let bucket = sessionBuckets.first(where: { $0.id == burn.bucketId })
        else { return nil }
        if bucket.resetsAt < .distantFuture, secs >= bucket.resetsAt.timeIntervalSince(now) {
            return BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset")
        }
        return BurnVerdict(willHit: true, text: "At this pace, limit in ~\(formatBurn(secs))")
    }

    static func formatBurn(_ secs: TimeInterval) -> String {
        let h = Int(secs / 3600)
        let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
        if h > 24 { return "\(h / 24)d" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
