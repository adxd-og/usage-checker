import Foundation

/// One charted reading of a quota window.
struct QuotaPoint: Equatable, Sendable, Identifiable {
    let time: Date
    /// Utilization clamped to 0...100 — providers occasionally report a hair over
    /// their own limit and a percentage axis shouldn't stretch to accommodate it.
    let percent: Double

    var id: Date { time }
}

/// The highest utilization one local day reached, and which window reached it.
struct DailyPeak: Equatable, Sendable, Identifiable {
    let day: Date
    let peak: Double
    let peakBucketID: String

    var id: Date { day }
}

/// What a provider's quota history says about how it is being used.
struct QuotaInsights: Equatable, Sendable {
    /// Days whose peak reached `QuotaAnalytics.capacityThreshold`.
    let daysAtCapacity: Int
    /// Days with at least one reading — how much of the span was observed at all.
    let daysObserved: Int
    /// Mean of the observed days' peaks, in percent.
    let averageDailyPeak: Double?
    /// The highest day on record, and the window that made it.
    let busiestDay: DailyPeak?
    /// Peak reached so far on `now`'s local day.
    let todayPeak: Double?
    /// Percent of a window consumed per observed day, resets counted: 250 means two
    /// and a half full windows a day.
    let averageDailyConsumption: Double?
    /// Local hour (0...23) that accumulates the most quota across the span.
    let busiestHour: Int?

    static let empty = QuotaInsights(
        daysAtCapacity: 0,
        daysObserved: 0,
        averageDailyPeak: nil,
        busiestDay: nil,
        todayPeak: nil,
        averageDailyConsumption: nil,
        busiestHour: nil
    )
}

/// A window the quota views can chart: its key in history plus how to name it today.
struct QuotaBucketInfo: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    /// The provider's real constraints, the ones allowed to colour a day in the
    /// activity grid or drive a summary figure.
    let isCore: Bool
    /// False for a window that exists only in history — the provider has stopped
    /// reporting it, so its name is inferred from the id and its line ends early.
    let isLive: Bool
}

/// Quota over time, for providers that keep no local cost log.
///
/// Antigravity, Gemini and Codex never expose what a turn consumed — the API answers
/// in quota fractions and nothing on disk says more. For a subscription that is not a
/// gap: consumption *is* the quota, so the same charts the cost tabs draw in dollars
/// are drawn here in percent, out of the history the app has been recording all along.
///
/// Pure and free of `Date()` defaults where a caller can supply one, so the whole
/// thing is testable without a clock (same contract as `Analytics`).
enum QuotaAnalytics {
    /// A day counted as "at capacity". Not 100: providers round, some stop updating
    /// once the limit is hit, and a window driven to 97% was every bit as much in the
    /// way as one that reached the round number.
    static let capacityThreshold: Double = 95

    /// Default resolution of a charted series. Roughly one point per horizontal
    /// pixel of the dashboard's chart — beyond that the extra points cost layout
    /// time and draw on top of each other.
    static let defaultMaxPoints = 500

    static func clamp(_ percent: Double) -> Double { max(0, min(100, percent)) }

    // MARK: - Series

    /// Downsampled utilization series for one bucket, at most `maxPoints` long.
    ///
    /// Bins by time and keeps each bin's MAXIMUM rather than its mean. Ninety days of
    /// minute-resolution history is well over 100k readings, and averaging them would
    /// smooth away exactly the peaks a quota chart exists to show — the whole question
    /// is "how close did I come to the limit", not "where did the line sit on average".
    /// Each surviving point keeps the timestamp of the reading that produced it, so a
    /// spike stays where it happened instead of snapping to a bin boundary.
    ///
    /// Records with no reading for `bucketID` are skipped rather than treated as zero:
    /// a provider that wasn't reporting is not a provider that was idle.
    static func series(
        records: [HistoryRecord],
        bucketID: String,
        from: Date,
        to: Date,
        maxPoints: Int = QuotaAnalytics.defaultMaxPoints
    ) -> [QuotaPoint] {
        guard maxPoints > 0, to >= from else { return [] }
        let binWidth = to.timeIntervalSince(from) / Double(maxPoints)

        var best: [Int: QuotaPoint] = [:]
        best.reserveCapacity(min(maxPoints, records.count))
        for record in records {
            let time = record.timestamp
            guard time >= from, time <= to, let raw = record.percent(for: bucketID) else { continue }
            // A zero-width span (from == to) collapses to a single bin instead of
            // dividing by zero.
            let bin = binWidth > 0
                ? min(maxPoints - 1, Int(time.timeIntervalSince(from) / binWidth))
                : 0
            let point = QuotaPoint(time: time, percent: clamp(raw))
            guard let existing = best[bin] else {
                best[bin] = point
                continue
            }
            // The earliest reading wins a flat bin, so the output doesn't depend on the
            // order records happened to arrive in.
            if point.percent > existing.percent
                || (point.percent == existing.percent && point.time < existing.time) {
                best[bin] = point
            }
        }
        return best.values.sorted { $0.time < $1.time }
    }

    // MARK: - Daily peaks

    /// Per local calendar day, the highest utilization any of `bucketIDs` reached.
    ///
    /// Days with no reading for any of the buckets are absent from the result rather
    /// than present at zero: "the app wasn't running" and "the quota stayed at zero"
    /// are different facts and the activity grid paints them differently. Ties go to
    /// the first bucket in `bucketIDs`, which keeps the attribution stable.
    static func dailyPeaks(
        records: [HistoryRecord],
        bucketIDs: [String],
        calendar: Calendar = .current
    ) -> [DailyPeak] {
        guard !bucketIDs.isEmpty else { return [] }
        var best: [Date: DailyPeak] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            for bucketID in bucketIDs {
                guard let raw = record.percent(for: bucketID) else { continue }
                let percent = clamp(raw)
                if let existing = best[day], existing.peak >= percent { continue }
                best[day] = DailyPeak(day: day, peak: percent, peakBucketID: bucketID)
            }
        }
        return best.values.sorted { $0.day < $1.day }
    }

    // MARK: - Insights

    /// Summary figures for the Insights tab's quota half.
    static func insights(
        records: [HistoryRecord],
        bucketIDs: [String],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> QuotaInsights {
        let peaks = dailyPeaks(records: records, bucketIDs: bucketIDs, calendar: calendar)
        guard !peaks.isEmpty else { return .empty }

        let today = calendar.startOfDay(for: now)
        var busiestDay: DailyPeak?
        var atCapacity = 0
        var peakTotal = 0.0
        var todayPeak: Double?
        for peak in peaks {
            peakTotal += peak.peak
            if peak.peak >= capacityThreshold { atCapacity += 1 }
            // Strictly greater: an earlier day keeps the title when two days tie.
            if peak.peak > (busiestDay?.peak ?? -1) { busiestDay = peak }
            if peak.day == today { todayPeak = peak.peak }
        }

        // Consumption, unlike the peak, counts what a window gave back. A 5-hour quota
        // driven to 80% four times in one day is 320% consumed, and a chart of peaks
        // alone would call that an 80% day. Only rises count — a fall is the window
        // starting over, never usage going down (the rule `Analytics.sinceLastReset`
        // applies to burn rate).
        var hourly = [Double](repeating: 0, count: 24)
        var mostConsumed = 0.0
        for bucketID in bucketIDs {
            let series = records
                .compactMap { record -> (time: Date, percent: Double)? in
                    guard let raw = record.percent(for: bucketID) else { return nil }
                    return (record.timestamp, clamp(raw))
                }
                .sorted { $0.time < $1.time }
            guard series.count >= 2 else { continue }

            var consumed = 0.0
            for i in series.indices.dropFirst() {
                let delta = series[i].percent - series[i - 1].percent
                guard delta > 0 else { continue }
                consumed += delta
                hourly[calendar.component(.hour, from: series[i].time)] += delta
            }
            // The largest single bucket, never the sum: a session window and the weekly
            // window it rolls up into both move on the same work, and adding them would
            // count that work twice.
            mostConsumed = max(mostConsumed, consumed)
        }

        var busiestHour: Int?
        for hour in hourly.indices where hourly[hour] > (busiestHour.map { hourly[$0] } ?? 0) {
            busiestHour = hour
        }

        return QuotaInsights(
            daysAtCapacity: atCapacity,
            daysObserved: peaks.count,
            averageDailyPeak: peakTotal / Double(peaks.count),
            busiestDay: busiestDay,
            todayPeak: todayPeak,
            averageDailyConsumption: mostConsumed > 0 ? mostConsumed / Double(peaks.count) : nil,
            busiestHour: busiestHour
        )
    }

    // MARK: - Buckets

    /// The provider's real constraints, by the same rule the menu bar headline uses:
    /// promotional pools are free bonuses and a model-scoped cap is one model's
    /// ceiling, so neither should colour a day in the activity grid. The fallbacks
    /// matter for an account that has nothing else — a grid with no squares at all
    /// would be worse than one drawn from a promo pool.
    static func coreBuckets(of buckets: [UsageBucket]) -> [UsageBucket] {
        let core = buckets.filter { !$0.isPromotional && $0.kind != .modelSpecific }
        if !core.isEmpty { return core }
        let nonPromotional = buckets.filter { !$0.isPromotional }
        return nonPromotional.isEmpty ? buckets : nonPromotional
    }

    /// Every bucket id these records carry, sorted so the order is stable.
    ///
    /// Only the generic `bucketPercents` map is consulted. The legacy fixed fields
    /// exist solely for Claude, which always has a live snapshot to name its windows
    /// from and never needs this fallback.
    static func bucketIDs(in records: [HistoryRecord]) -> [String] {
        var ids = Set<String>()
        for record in records {
            guard let percents = record.bucketPercents else { continue }
            ids.formUnion(percents.keys)
        }
        return ids.sorted()
    }

    /// Every window the quota views can offer for one provider: the live ones first, in
    /// the order the provider lists them, then any that survive only in history.
    ///
    /// Labels have to come from the live snapshot — a `HistoryRecord` stores bucket ids
    /// and percentages and nothing else. A window the provider has stopped reporting
    /// (renamed, or dropped with a plan change) still has months of readings behind it,
    /// so it keeps a name inferred from its id rather than vanishing from the chart.
    /// It is never core: with a live snapshot on hand, a window absent from it is not a
    /// constraint the user is under today.
    static func bucketInfos(service: ServiceSnapshot?, records: [HistoryRecord]) -> [QuotaBucketInfo] {
        let live = service?.buckets ?? []
        let coreIDs = Set(coreBuckets(of: live).map(\.id))
        var infos = live.map {
            QuotaBucketInfo(id: $0.id, label: $0.label, isCore: coreIDs.contains($0.id), isLive: true)
        }
        var seen = Set(infos.map(\.id))
        for id in bucketIDs(in: records) where seen.insert(id).inserted {
            // A signed-out provider has no live snapshot at all; without this its whole
            // history would be non-core and the activity grid would come up blank.
            let isCore = live.isEmpty && !id.lowercased().contains("promo")
            infos.append(QuotaBucketInfo(id: id, label: prettifiedLabel(for: id), isCore: isCore, isLive: false))
        }
        return infos
    }

    /// A readable name for a window the provider no longer reports. Bucket ids are
    /// snake_case and self-describing ("gemini_pro", "seven_day_opus"), so word-casing
    /// one beats showing the raw key.
    static func prettifiedLabel(for bucketID: String) -> String {
        let words = bucketID.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard !words.isEmpty else { return bucketID }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
