import Foundation

/// The quota calendar's figure: how many of the range's recorded days reached the
/// limit (`QuotaAnalytics.daysAtCapacity`, spec § Decisions "What limit hit counts").
struct HistoryCalendarQuotaSummary: Equatable, Sendable {
    let daysAtLimit: Int
    let daysObserved: Int
}

/// History → Calendar's rules (liquid-glass spec § Screens, "History · Calendar").
enum HistoryCalendarRules {
    /// Week columns from the week holding the range's first day to the week holding
    /// `now`, weeks as the Mac's calendar runs them (`GridCache.weekStart`).
    static func weeks(from windowStart: Date, now: Date, calendar: Calendar) -> Int {
        let first = GridCache.weekStart(of: windowStart, calendar: calendar)
        let last = GridCache.weekStart(of: now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        return max(1, days / 7 + 1)
    }

    /// A cost square's step on the mockup's ramp: 0 for an empty day, then one step
    /// per quarter of the range's busiest day.
    static func costLevel(intensity: Double) -> Int {
        let clamped = max(0, min(1, intensity))
        guard clamped > 0 else { return 0 }
        return min(4, Int((clamped * 4).rounded(.up)))
    }

    /// The yolk's strength per step: the mockup's `color-mix` 28, 50, 75 and 100 %.
    /// Step 0 is the `calendarEmpty` square, not yolk.
    static func levelOpacity(_ level: Int) -> Double {
        switch level {
        case ...0: return 0
        case 1: return 0.28
        case 2: return 0.50
        case 3: return 0.75
        default: return 1
        }
    }

    /// The legend's squares, "Less" to "More".
    static let legendLevels = [0, 1, 2, 3, 4]

    // MARK: The range's bounds (review finding F2)

    /// Where the range ends, exclusive: the start of tomorrow, the today-inclusive
    /// bound Overview's totals use. A reading or a row stamped later — a clock set back
    /// after it was written — belongs to no day the grid draws.
    static func windowEnd(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// The cost rows the calendar draws: re-keyed to `calendar`'s days, then only the
    /// range's (`HistoryRules.windowStart` up to `windowEnd`), so the ramp's top step
    /// is the range's busiest day.
    static func costRows(_ daily: [CLIDailySummary], range: TimeRange, now: Date, calendar: Calendar) -> [CLIDailySummary] {
        let start = HistoryRules.windowStart(range: range, now: now, calendar: calendar)
        let end = windowEnd(now: now, calendar: calendar)
        return GridCache.dailiesByDay(daily, calendar: calendar).filter { $0.day >= start && $0.day < end }
    }

    /// The quota readings the calendar draws: the range's, up to `windowEnd`.
    static func quotaRecords(_ records: [HistoryRecord], range: TimeRange, now: Date, calendar: Calendar) -> [HistoryRecord] {
        let start = HistoryRules.windowStart(range: range, now: now, calendar: calendar)
        let end = windowEnd(now: now, calendar: calendar)
        return records.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    /// The quota calendar's figure over the range's readings: days whose core-window
    /// peak reached the limit, of the days recorded.
    static func quotaSummary(
        records: [HistoryRecord], buckets: [QuotaBucketInfo],
        range: TimeRange, now: Date, calendar: Calendar
    ) -> HistoryCalendarQuotaSummary {
        let insights = QuotaAnalytics.insights(
            records: quotaRecords(records, range: range, now: now, calendar: calendar),
            bucketIDs: buckets.filter(\.isCore).map(\.id),
            calendar: calendar, now: now
        )
        return HistoryCalendarQuotaSummary(daysAtLimit: insights.daysAtCapacity, daysObserved: insights.daysObserved)
    }
}
