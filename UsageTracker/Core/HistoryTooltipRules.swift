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
