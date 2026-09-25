import Foundation

/// A day and what was spent on it.
struct InsightsDayCost: Equatable, Sendable {
    let day: Date
    let cost: Double
}

/// A model and its dollars.
struct InsightsModelCost: Equatable, Sendable {
    let model: String
    let cost: Double
}

/// The mean spend of the days that had any, and how many there were.
struct InsightsDailyAverage: Equatable, Sendable {
    /// nil when not one day had spend.
    let average: Double?
    let activeDays: Int
}

/// Every figure the Insights tab can show.
enum InsightsFigure: String, CaseIterable, Identifiable, Sendable {
    case weekOverWeek, daysAtLimit, dailyAverage, biggestDay, mostUsedModelToday
    case averageDailyPeak, quotaPerDay, busiestQuotaDay, busiestHour

    var id: String { rawValue }
}

/// What every figure is computed from, built in one pass off the main actor: it reduces
/// over the daily rows and the whole quota history, far too heavy for a view's body.
struct InsightsSummary: Equatable, Sendable {
    let weekOverWeek: WeekOverWeek
    let dailyAverage: InsightsDailyAverage
    let biggestDay: InsightsDayCost?
    let mostUsedModelToday: InsightsModelCost?
    let daysAtLimit: QuotaDaysAtCapacity
    /// `.empty` for a provider with a cost log: nothing on its page reads it.
    let quota: QuotaInsights

    static let empty = InsightsSummary(
        weekOverWeek: .empty,
        dailyAverage: InsightsDailyAverage(average: nil, activeDays: 0),
        biggestDay: nil,
        mostUsedModelToday: nil,
        daysAtLimit: QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: InsightsRules.daysAtLimitSpan),
        quota: .empty
    )
}

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
    /// One model's line in `CLIBreakdown.byModelToday` and `WindowUsage.models`.
    typealias ModelEntry = (model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)

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

    /// Every figure's inputs for one provider: its cost log's summary (nil without one),
    /// its quota history and core windows, and whether it has a cost log at all.
    static func summary(
        cli: CLIBreakdown?,
        history: [HistoryRecord],
        coreBucketIDs: [String],
        hasCostLog: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> InsightsSummary {
        let dailies = cli?.daily ?? []
        // 2.x's thirty days: a rolling cut from `now`.
        let last30 = dailies.filter { $0.day >= now.addingTimeInterval(-30 * 24 * 3600) }
        let active = last30.filter { $0.totalCost > 0 }
        return InsightsSummary(
            weekOverWeek: weekOverWeek(dailies: dailies, now: now, calendar: calendar),
            dailyAverage: InsightsDailyAverage(
                average: active.isEmpty ? nil : active.map(\.totalCost).reduce(0, +) / Double(active.count),
                activeDays: active.count
            ),
            biggestDay: InsightsView.peakDay(in: dailies, now: now, calendar: calendar)
                .map { InsightsDayCost(day: $0.day, cost: $0.cost) },
            mostUsedModelToday: mostUsedModelToday(cli?.byModelToday ?? []),
            daysAtLimit: daysAtLimit(records: history, bucketIDs: coreBucketIDs, now: now, calendar: calendar),
            // Only a provider without a cost log shows these. Claude has months of
            // history across half a dozen windows, and walking all of it every poll to
            // fill cards nobody sees is pure waste.
            quota: hasCostLog
                ? .empty
                : QuotaAnalytics.insights(records: history, bucketIDs: coreBucketIDs, calendar: calendar, now: now)
        )
    }

    /// This week and last as the two latest runs of seven local days: today and the six
    /// before it, then the seven before those. Calendar days, not 7 × 86 400 s: every
    /// `CLIDailySummary.day` is a day start, and a cut at the current time of day moves
    /// a day across the boundary on a clock change (the `ActivityCardRule` lesson).
    static func weekOverWeek(dailies: [CLIDailySummary], now: Date, calendar: Calendar = .current) -> WeekOverWeek {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let thisWeekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let lastWeekStart = calendar.date(byAdding: .day, value: -13, to: today)
        else { return .empty }
        var thisWeek = 0.0
        var lastWeek = 0.0
        for daily in dailies where daily.day < tomorrow {
            if daily.day >= thisWeekStart {
                thisWeek += daily.totalCost
            } else if daily.day >= lastWeekStart {
                lastWeek += daily.totalCost
            }
        }
        return WeekOverWeek(thisWeek: thisWeek, lastWeek: lastWeek)
    }

    /// Today's dearest model. `byModelToday` is today's already: the aggregators cut it
    /// at the local day's start. Picked here rather than trusted in order, because equal
    /// costs come out of a dictionary in any order: ties go to the name first in the
    /// alphabet.
    static func mostUsedModelToday(_ byModelToday: [ModelEntry]) -> InsightsModelCost? {
        byModelToday
            .min { a, b in a.cost != b.cost ? a.cost > b.cost : a.model < b.model }
            .map { InsightsModelCost(model: $0.model, cost: $0.cost) }
    }

    /// A window's name: the live snapshot's label, or one inferred from its id when the
    /// provider has stopped reporting it.
    static func windowLabel(for bucketID: String, in buckets: [QuotaBucketInfo]) -> String {
        buckets.first(where: { $0.id == bucketID })?.label ?? QuotaAnalytics.prettifiedLabel(for: bucketID)
    }
}
