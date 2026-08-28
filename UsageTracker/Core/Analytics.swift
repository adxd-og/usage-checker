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

/// A time-based nudge for a session window, when one is warranted.
enum PacingAdvice: Equatable, Sendable {
    /// The window will hit 100% before it resets, within the warning horizon.
    case burningFast(secondsToLimit: TimeInterval)
    /// The window is nearly over and the user is pressed against it.
    case aboutToReset
}

extension Analytics {
    /// Decides whether a session window deserves a nudge right now.
    ///
    /// Kept separate from the notifier so the rules are testable on their own — the
    /// interesting part is what does *not* fire: a fast pace that still resets in time
    /// is not a problem, and a reset is only news if you're actually pressed against
    /// the limit.
    static func pacingAdvice(
        percent: Double,
        untilReset: TimeInterval,
        prediction: BurnRatePrediction?,
        leadSeconds: TimeInterval,
        resetLeadSeconds: TimeInterval,
        highWaterMark: Double,
        wantsPace: Bool,
        wantsReset: Bool
    ) -> PacingAdvice? {
        guard untilReset > 0 else { return nil }

        // A reset within minutes outranks a pace warning: the squeeze ends either way,
        // and "it's about to start over" is the more actionable of the two.
        if wantsReset, untilReset <= resetLeadSeconds, percent >= highWaterMark {
            return .aboutToReset
        }

        guard wantsPace, percent < 100,
              let prediction, !prediction.isStale,
              let secondsToLimit = prediction.secondsToLimit,
              secondsToLimit <= leadSeconds,
              secondsToLimit < untilReset
        else { return nil }

        return .burningFast(secondsToLimit: secondsToLimit)
    }
}
