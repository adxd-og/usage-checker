import Foundation

/// The decisions History's page takes about its controls and its days (liquid-glass
/// spec § Screens, "History · Chart", "History · Calendar", "History · quota-only
/// provider"). Pure, nonisolated and tested; the views only draw what these say.
/// Each `extension` below is one concern.
enum HistoryRules {}

// MARK: - Cost and Tokens

extension HistoryRules {
    /// The units the chart offers. The chat list is no longer a mode: it sits under the
    /// chart in both (spec § Screens, "History · Chart").
    static let chartModes: [HistoryChartMode] = [.cost, .tokens]

    /// The unit in force for a stored value. `sessions`, 2.x's third mode, can still be
    /// in `historyChartMode`; it reads as Cost, with the chat list under the chart.
    static func effectiveMode(stored: HistoryChartMode) -> HistoryChartMode {
        chartModes.contains(stored) ? stored : .cost
    }
}

// MARK: - Ranges

extension HistoryRules {
    /// The ranges History offers, in the mockups' order. 5h stays a `TimeRange` for
    /// Agents; a chart of whole days has nothing to say about five hours.
    static let ranges: [TimeRange] = [.oneDay, .sevenDays, .thirtyDays, .ninetyDays, .oneYear]

    /// The range History shows for the shared `DashboardState.range`: itself when
    /// History offers it, otherwise a day (the one it cannot offer is Agents' 5h).
    static func offeredRange(_ stored: TimeRange) -> TimeRange {
        ranges.contains(stored) ? stored : .oneDay
    }
}

// MARK: - The range's days

/// One calendar day of the selected provider's cost log, as History draws it.
struct HistoryDay: Equatable, Sendable, Identifiable {
    let day: Date
    let cost: Double
    /// The CLI's own headline figure; for Grok it can differ from `breakdown.total`.
    let tokens: Int
    let turns: Int
    let breakdown: TokenBreakdown

    var id: Date { day }
}

/// What a card's header says about the range: how many days it covers, what they cost,
/// and on how many of them anything was spent.
struct HistoryRangeSummary: Equatable, Sendable {
    let dayCount: Int
    let cost: Double
    let activeDays: Int
}

extension HistoryRules {
    /// How many calendar days a day range covers, today included: 7, and
    /// `ActivityCardRule`'s 30, 90 and 365. nil for 24h and 5h, which stay rolling.
    static func calendarDays(_ range: TimeRange) -> Int? {
        switch range {
        case .fiveHours, .oneDay: return nil
        case .sevenDays: return 7
        case .thirtyDays: return ActivityCardRule.thirtyDays
        case .ninetyDays: return ActivityCardRule.ninetyDays
        case .oneYear: return ActivityCardRule.yearDays
        }
    }

    /// The first day the range covers (session ruling S1). A day range is that many
    /// calendar days ending today, cut with `ActivityCardRule`'s formula — the start of
    /// the day N − 1 days back — so History's 7d and 30d sum the days Overview's "Last
    /// 7 days" and "Last 30 days" sum. 24h stays rolling: the local day 24 h ago.
    static func windowStart(range: TimeRange, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let days = calendarDays(range) else {
            return calendar.startOfDay(for: now.addingTimeInterval(-range.seconds))
        }
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }

    /// Calendar days from `windowStart` through today, whether or not they have rows.
    static func dayCount(range: TimeRange, now: Date, calendar: Calendar) -> Int {
        let start = windowStart(range: range, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
    }

    /// The range's days that have a row, ascending. Rows are re-keyed to `calendar`
    /// first (`GridCache.dailiesByDay`), as the Calendar re-keys them, so both views
    /// sum the same rows.
    static func days(daily: [CLIDailySummary], range: TimeRange, now: Date, calendar: Calendar) -> [HistoryDay] {
        let start = windowStart(range: range, now: now, calendar: calendar)
        return GridCache.dailiesByDay(daily, calendar: calendar)
            .filter { $0.day >= start && $0.day <= now }
            .map {
                HistoryDay(
                    day: $0.day, cost: $0.totalCost, tokens: $0.totalTokens,
                    turns: $0.turns, breakdown: $0.tokens
                )
            }
    }

    /// The card header's figures: the range's days, the sum of its bars, the days with
    /// dollars on them.
    static func summary(_ days: [HistoryDay], range: TimeRange, now: Date, calendar: Calendar) -> HistoryRangeSummary {
        HistoryRangeSummary(
            dayCount: dayCount(range: range, now: now, calendar: calendar),
            cost: days.reduce(0) { $0 + $1.cost },
            activeDays: days.filter { $0.cost > 0 }.count
        )
    }

    /// The chart's x extent: the whole range, empty days included, to the end of today.
    static func xDomain(range: TimeRange, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let start = windowStart(range: range, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }
}

// MARK: - The chart's look

extension HistoryRules {
    static func isToday(_ day: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    /// Today's bar in full yolk, every other day at half (`Dashboard-History-Cost`).
    static func barOpacity(isToday: Bool) -> Double {
        isToday ? 1 : 0.5
    }

    /// The most bars that still carry their figure on top: 7d draws 7 with room to
    /// spare; at 30 the figures would overlap.
    static let maxLabelledBars = 10

    static func showsValueLabels(dayCount: Int) -> Bool {
        dayCount <= maxLabelledBars
    }

    /// Every how many days a date sits under the bars: about eight dates at any range.
    static func axisStride(dayCount: Int) -> Int {
        max(1, dayCount / 8)
    }

    /// The mockup's 7 pt corners while a bar is wide enough to hold them; a bar in a
    /// 90-day or year chart is a few points wide and gets 2.
    static func barCornerRadius(dayCount: Int) -> CGFloat {
        dayCount <= 31 ? 7 : 2
    }
}

// MARK: - Hover

extension HistoryRules {
    /// The day under the pointer: the row whose local day holds `date`, if it has one.
    static func day(containing date: Date, in days: [HistoryDay], calendar: Calendar) -> HistoryDay? {
        let start = calendar.startOfDay(for: date)
        return days.first { $0.day == start }
    }
}

// MARK: - Quota-only provider

/// One window's line on the quota chart: its name from the live snapshot, its readings
/// binned by `QuotaAnalytics.series`.
struct HistoryQuotaSeries: Equatable, Sendable, Identifiable {
    let bucket: QuotaBucketInfo
    let points: [QuotaPoint]

    var id: String { bucket.id }
}

/// The quota chart as one value: its x extent and the lines over it, computed with
/// one `now` (`HistoryRules.quotaChart`), so the page's cache and the card's axis
/// cannot disagree about the range.
struct HistoryQuotaChart: Equatable, Sendable {
    let domain: ClosedRange<Date>
    let series: [HistoryQuotaSeries]
}

/// How often a mark sits on the quota chart's time axis.
struct HistoryAxisStride: Equatable, Sendable {
    let component: Calendar.Component
    let count: Int
}

extension HistoryRules {
    /// The lines' colours in the provider's window order (`Dashboard-Quota-History`).
    static let quotaSeriesTokens: [OMColorToken] = [
        .tokenCacheRead, .seriesSession, .seriesQuota, .seriesAllModels, .seriesPerModel, .tokenOutput,
    ]

    /// A seventh window starts the colours again.
    static func quotaSeriesToken(index: Int) -> OMColorToken {
        let count = quotaSeriesTokens.count
        return quotaSeriesTokens[((index % count) + count) % count]
    }

    /// A fixed 0–100 % axis in quarters: half the point is the headroom left, which a
    /// fitted axis hides.
    static let quotaAxisValues: [Double] = [0, 25, 50, 75, 100]

    /// Hours for a day, days for a week or a month, months for a year.
    static func quotaAxisStride(range: TimeRange) -> HistoryAxisStride {
        switch range {
        case .fiveHours: return HistoryAxisStride(component: .hour, count: 1)
        case .oneDay: return HistoryAxisStride(component: .hour, count: 4)
        case .sevenDays: return HistoryAxisStride(component: .day, count: 1)
        case .thirtyDays: return HistoryAxisStride(component: .day, count: 4)
        case .ninetyDays: return HistoryAxisStride(component: .day, count: 12)
        case .oneYear: return HistoryAxisStride(component: .month, count: 1)
        }
    }

    /// The quota chart's extent (review finding F1): the cost chart's days for 7d, 30d,
    /// 90d and 1y (`windowStart`, ruling S1) through now, so Chart and Calendar agree on
    /// what a range covers; 24h is the rolling 24 hours.
    static func quotaDomain(range: TimeRange, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        guard calendarDays(range) != nil else { return now.addingTimeInterval(-range.seconds)...now }
        return windowStart(range: range, now: now, calendar: calendar)...now
    }

    /// One line per window over `quotaDomain`, core or not: a promotional pool is still
    /// quota the user can watch drain. A window with no reading in the range has no line.
    static func quotaSeries(
        records: [HistoryRecord], buckets: [QuotaBucketInfo],
        range: TimeRange, now: Date, calendar: Calendar
    ) -> [HistoryQuotaSeries] {
        let domain = quotaDomain(range: range, now: now, calendar: calendar)
        return buckets.compactMap { bucket in
            let points = QuotaAnalytics.series(
                records: records, bucketID: bucket.id, from: domain.lowerBound, to: domain.upperBound
            )
            return points.isEmpty ? nil : HistoryQuotaSeries(bucket: bucket, points: points)
        }
    }

    /// The domain and the lines together, from the same `now`: what the page caches and
    /// the card draws.
    static func quotaChart(
        records: [HistoryRecord], buckets: [QuotaBucketInfo],
        range: TimeRange, now: Date, calendar: Calendar
    ) -> HistoryQuotaChart {
        HistoryQuotaChart(
            domain: quotaDomain(range: range, now: now, calendar: calendar),
            series: quotaSeries(records: records, buckets: buckets, range: range, now: now, calendar: calendar)
        )
    }
}

// MARK: - Chart or Calendar

/// Which of History's two presentations is on screen. Persisted under
/// `HistoryRules.viewModeKey`, so the raw values are a storage contract.
enum HistoryViewMode: String, CaseIterable, Identifiable, Sendable {
    case chart, calendar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chart: return "Chart"
        case .calendar: return "Calendar"
        }
    }
}

extension HistoryRules {
    static let viewModeKey = "historyView"

    /// The day a History cache was built for. The chart's domain and the calendar's
    /// "today" come from the clock, not from the records, so a cache keyed on the
    /// records alone stands still across midnight when a provider has stopped
    /// reporting; the key carries this instead.
    static func cacheDay(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    /// Whether Cost/Tokens is drawn: only over a chart of a cost log. The calendar is
    /// cost only (spec § Decisions, "Calendar in Tokens mode"), and a quota-only
    /// provider has one unit.
    static func showsModePicker(view: HistoryViewMode, showsQuota: Bool) -> Bool {
        view == .chart && !showsQuota
    }
}
