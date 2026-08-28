import Foundation

/// Predicted time-to-limit based on recent burn rate.
struct BurnRatePrediction: Sendable, Equatable {
    /// Estimated seconds until 100%. nil if not enough data or burn rate is zero/negative.
    let secondsToLimit: TimeInterval?
    /// Percent change per minute. 0 means no detectable growth.
    let percentPerMinute: Double
    /// Bucket the prediction is for ("five_hour" or "seven_day").
    let bucketId: String
    /// True when the newest reading the prediction is built from is already old
    /// enough that acting on it would be a guess (see `Analytics.staleAfter`).
    let isStale: Bool
}

enum Analytics {
    /// A fall this large between two consecutive readings is a window starting over,
    /// not usage going down — a rate limit only ever climbs until it resets.
    static let resetDropThreshold: Double = 10

    /// How old the newest reading may be before the prediction stops being actionable.
    ///
    /// This used to be 30 minutes, which equalled the default lookback: every point in
    /// the slice was younger than the cutoff by construction, so `isStale` could never
    /// become true at all. Ten minutes is the honest figure — the pace alert warns 45
    /// minutes ahead, and a reading from ten minutes ago no longer says what is
    /// happening now.
    static let staleAfter: TimeInterval = 10 * 60

    /// Burn rate computed from the last `lookback` minutes of history for a single bucket.
    ///
    /// The slice is sorted before it is read (records arrive per provider and nothing
    /// guaranteed their order) and then cut at the newest reset inside it. Without the
    /// cut, a session that went 92% → 4% → 38% over 25 minutes had a *negative*
    /// end-to-end delta and produced no prediction for a full lookback — which is
    /// exactly the half hour after a reset when "burning fast" is worth saying.
    static func burnRate(records: [HistoryRecord], bucketId: String, lookbackMinutes: Double = 30) -> BurnRatePrediction? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackMinutes * 60)
        let series = records
            .filter { $0.timestamp >= cutoff }
            .compactMap { rec -> (Date, Double)? in
                guard let v = rec.percent(for: bucketId) else { return nil }
                return (rec.timestamp, v)
            }
            .sorted { $0.0 < $1.0 }

        let relevant = Self.sinceLastReset(series)
        guard relevant.count >= 2 else { return nil }

        let first = relevant.first!
        let last = relevant.last!
        // `>=`, not `>`: the history store spaces points at least 30 seconds apart, so
        // two points at exactly the minimum legal spacing are a legitimate trend and
        // were being thrown away.
        let deltaMinutes = last.0.timeIntervalSince(first.0) / 60.0
        guard deltaMinutes >= 0.5 else { return nil }

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
            isStale: staleness > staleAfter
        )
    }

    /// The tail of a chronological series that belongs to the current window: everything
    /// up to and including the newest reset is dropped, so the rate is measured on what
    /// has happened since. Returned as a slice — the caller only needs its ends.
    static func sinceLastReset(_ series: [(Date, Double)]) -> ArraySlice<(Date, Double)> {
        var start = series.startIndex
        for i in series.indices.dropFirst() where series[i - 1].1 - series[i].1 > resetDropThreshold {
            start = i
        }
        return series[start...]
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
