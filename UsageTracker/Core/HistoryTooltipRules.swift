import CoreGraphics
import Foundation

/// A tooltip's words: the day (or moment) on top, a figure right of it in Tokens mode,
/// then one label/value row per figure.
struct HistoryTooltip: Equatable, Sendable {
    let title: String
    let headline: String?
    let rows: [HistoryTooltipRow]
}

struct HistoryTooltipRow: Equatable, Sendable {
    let label: String
    let value: String
    /// A dot in this colour before the label: a token type's colour in Tokens mode
    /// (session ruling S2), nil for figures that have no colour of their own.
    var token: OMColorToken? = nil
}

/// The chart tooltip (liquid-glass spec § Components, "Chart tooltip"), which replaces
/// the per-day tables: what it says about a day, and where it sits beside its bar.
enum HistoryTooltipRules {
    /// `Dashboard-History-Cost`: a 176 pt bubble, 6 pt clear of its bar.
    static let chartWidth: CGFloat = 176
    static let gap: CGFloat = 6

    /// Cost: the day's dollars, turns and tokens. Tokens: the day's total beside the
    /// date, then each type with tokens, biggest first, ties in the legend's order.
    static func text(
        for day: HistoryDay, mode: HistoryChartMode,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> HistoryTooltip {
        let title = HistoryCopy.tooltipTitle(day.day, calendar: calendar, locale: locale)
        guard mode == .tokens else {
            return HistoryTooltip(title: title, headline: nil, rows: [
                HistoryTooltipRow(label: "Cost", value: HistoryCopy.dollars(day.cost)),
                HistoryTooltipRow(label: "Turns", value: HistoryCopy.count(day.turns)),
                HistoryTooltipRow(label: "Tokens", value: TokenFormat.formatTokens(day.tokens)),
            ])
        }
        // Typed in steps: as one chain the expression is too much for the type-checker.
        typealias Entry = (order: Int, category: TokenCategory, tokens: Int)
        let entries: [Entry] = TokenCategory.allCases.enumerated().map { pair -> Entry in
            (order: pair.offset, category: pair.element, tokens: pair.element.tokens(in: day.breakdown))
        }
        let ordered: [Entry] = entries
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens == $1.tokens ? $0.order < $1.order : $0.tokens > $1.tokens }
        let rows: [HistoryTooltipRow] = ordered.map { entry in
            HistoryTooltipRow(
                label: entry.category.label, value: TokenFormat.formatTokens(entry.tokens),
                token: entry.category.token
            )
        }
        return HistoryTooltip(title: title, headline: TokenFormat.formatTokens(day.tokens), rows: rows)
    }

    /// Where the bubble starts, in plot coordinates: `clearance` right of `anchorX`
    /// while it fits inside the plot, otherwise as far to the anchor's left, never left
    /// of the plot.
    static func leadingX(anchorX: CGFloat, clearance: CGFloat, width: CGFloat, plotWidth: CGFloat) -> CGFloat {
        let right = anchorX + clearance
        if right + width <= plotWidth { return right }
        return max(0, anchorX - clearance - width)
    }
}

// MARK: - Quota chart

/// What hovering the quota chart shows: the tooltip, and which reading the dot rings.
struct HistoryQuotaHover: Equatable, Sendable {
    let tooltip: HistoryTooltip
    let seriesID: String
    let point: QuotaPoint
}

extension HistoryTooltipRules {
    /// `Dashboard-Quota-History`: a 196 pt bubble 14 pt right of the dot, 10 pt above it.
    static let quotaWidth: CGFloat = 196
    static let quotaClearance: CGFloat = 14
    static let quotaLift: CGFloat = 10
    /// The mockup lists three of its six windows; more would hide the lines under it.
    static let maxQuotaRows = 3

    /// How far from the pointer a reading may be and still count: 1 % of the range. A
    /// window that has no reading that close was not being recorded there.
    static func tolerance(range: TimeRange) -> TimeInterval {
        range.seconds / 100
    }

    /// The reading nearest `time`; the earlier of two equally near.
    static func nearestPoint(in points: [QuotaPoint], to time: Date) -> QuotaPoint? {
        points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    /// The windows at the pointer, fullest first, ties in the provider's order, at most
    /// `maxQuotaRows`; nil when no window has a reading near it. A day-long chart names
    /// the time as well as the day.
    static func quotaHover(
        at time: Date, series: [HistoryQuotaSeries], range: TimeRange,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> HistoryQuotaHover? {
        let limit = tolerance(range: range)
        let hits = series.enumerated()
            .compactMap { entry -> (order: Int, series: HistoryQuotaSeries, point: QuotaPoint)? in
                guard let point = nearestPoint(in: entry.element.points, to: time),
                      abs(point.time.timeIntervalSince(time)) <= limit
                else { return nil }
                return (entry.offset, entry.element, point)
            }
            .sorted {
                $0.point.percent == $1.point.percent ? $0.order < $1.order : $0.point.percent > $1.point.percent
            }
        guard let top = hits.first else { return nil }
        let withTime = range == .oneDay || range == .fiveHours
        let tooltip = HistoryTooltip(
            title: HistoryCopy.tooltipTitle(time, withTime: withTime, calendar: calendar, locale: locale),
            headline: nil,
            rows: hits.prefix(maxQuotaRows).map {
                HistoryTooltipRow(label: $0.series.bucket.label, value: HistoryCopy.percent($0.point.percent))
            }
        )
        return HistoryQuotaHover(tooltip: tooltip, seriesID: top.series.id, point: top.point)
    }
}
