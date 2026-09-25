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
