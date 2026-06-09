import Foundation

/// Predicted time-to-limit based on recent burn rate.
struct BurnRatePrediction: Sendable, Equatable {
    /// Estimated seconds until 100%. nil if not enough data or burn rate is zero/negative.
    let secondsToLimit: TimeInterval?
    /// Percent change per minute. 0 means no detectable growth.
    let percentPerMinute: Double
    /// Bucket the prediction is for ("five_hour" or "seven_day").
    let bucketId: String
    /// True if the prediction is older than ~30 minutes and may be stale.
    let isStale: Bool
}

enum Analytics {
    /// Burn rate computed from the last `lookback` minutes of history for a single bucket.
    static func burnRate(records: [HistoryRecord], bucketId: String, lookbackMinutes: Double = 30) -> BurnRatePrediction? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackMinutes * 60)
        let relevant = records
            .filter { $0.timestamp >= cutoff }
            .compactMap { rec -> (Date, Double)? in
                guard let v = rec.percent(for: bucketId) else { return nil }
                return (rec.timestamp, v)
            }

        guard relevant.count >= 2 else { return nil }

        let first = relevant.first!
        let last = relevant.last!
        let deltaMinutes = last.0.timeIntervalSince(first.0) / 60.0
        guard deltaMinutes > 0.5 else { return nil }

        let deltaPercent = last.1 - first.1
        let rate = deltaPercent / deltaMinutes
        let remaining = 100.0 - last.1
        let staleness = now.timeIntervalSince(last.0)

        let secondsToLimit: TimeInterval?
        if rate > 0.05 && remaining > 0 {
            secondsToLimit = (remaining / rate) * 60.0
        } else {
            secondsToLimit = nil
        }

        return BurnRatePrediction(
            secondsToLimit: secondsToLimit,
            percentPerMinute: max(0, rate),
            bucketId: bucketId,
            isStale: staleness > 30 * 60
        )
    }
}
