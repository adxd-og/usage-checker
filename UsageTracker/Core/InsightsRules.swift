import Foundation

/// What the Insights pass is computed from, as `.task(id:)` sees it: a new value is a
/// new pass. The local day is part of it (review F1), so "Days at limit" and every
/// "today" figure move on at midnight even when nothing else changed. The view reads it
/// on every body evaluation, and the dashboard re-evaluates the tab on each poll while
/// the window is on screen and refreshes when the window comes back, so the new day is
/// picked up at the next of either.
struct InsightsCacheKey: Hashable, Sendable {
    let service: String
    let cliUpdatedAt: Date
    let historyCount: Int
    let lastHistoryAt: Date
    let quotaBucketIDs: [String]
    let day: Date
}

/// What the Insights tab decides (liquid-glass spec § Screens, "Insights"; § Decisions,
/// "What limit hit counts"). Pure: the clock and the calendar come in as arguments.
enum InsightsRules {
    /// "Days at limit, 7 days": today and the six local days before it.
    static let daysAtLimitSpan = 7

    /// Of the last seven local days, the ones whose peak across the provider's core
    /// windows reached `QuotaAnalytics.capacityThreshold`, and how many of the seven had
    /// a reading at all. Every provider is sampled into `HistoryStore` on each poll, so
    /// the figure means the same for Claude and for a provider without a cost log.
    static func daysAtLimit(
        records: [HistoryRecord],
        bucketIDs: [String],
        now: Date,
        calendar: Calendar = .current
    ) -> QuotaDaysAtCapacity {
        QuotaAnalytics.daysAtCapacity(
            records: records,
            bucketIDs: bucketIDs,
            lastDays: daysAtLimitSpan,
            now: now,
            calendar: calendar
        )
    }

    /// The key the Insights pass runs under, with the local day of `now` in it.
    static func cacheKey(
        service: String,
        cliUpdatedAt: Date,
        historyCount: Int,
        lastHistoryAt: Date,
        quotaBucketIDs: [String],
        now: Date,
        calendar: Calendar = .current
    ) -> InsightsCacheKey {
        InsightsCacheKey(
            service: service,
            cliUpdatedAt: cliUpdatedAt,
            historyCount: historyCount,
            lastHistoryAt: lastHistoryAt,
            quotaBucketIDs: quotaBucketIDs,
            day: calendar.startOfDay(for: now)
        )
    }
}
