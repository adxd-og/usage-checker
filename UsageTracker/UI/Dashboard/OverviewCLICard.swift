import SwiftUI

/// The CLI card's rules: its "Last 7 days" and "Last 30 days", and its metrics
/// (`Dashboard-Overview(-Light).dc.html`).
enum OverviewCLIRules {
    // MARK: - Metrics

    static let topPadding: CGFloat = 24
    static let horizontalPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 22
    static let spacing: CGFloat = 16
    static let headSpacing: CGFloat = 2
    static let titleSize: CGFloat = 13
    static let headlineSize: CGFloat = 44
    static let headlineTracking: CGFloat = -1
    static let todayLineSize: CGFloat = 12.5
    static let figureSpacing: CGFloat = 32
    static let figureLabelSize: CGFloat = 12
    static let figureSize: CGFloat = 18
    static let captionSize: CGFloat = 11

    /// The calendar days "Last 7 days" and "Last 30 days" cover, today included.
    static let weekDays = 7
    static let monthDays = 30

    // MARK: - Figures

    /// The first day of the last `days` calendar days, today included: the start of the
    /// day `days − 1` back, as `ActivityCardRule` counts its "Last 30 days".
    static func cutoff(lastDays days: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
    }

    /// Dollars over the last `days` calendar days, today included, from the log's daily
    /// rows. Calendar days rather than the aggregator's rolling `weekCost` / `monthCost`:
    /// the figure is the sum of the bars it sits under, and the same thirty days History's
    /// calendar counts. A row dated after today (a clock set back, a future-stamped log)
    /// has no bar, so it is not counted either.
    static func cost(daily: [CLIDailySummary], lastDays days: Int, now: Date, calendar: Calendar) -> Double {
        let from = cutoff(lastDays: days, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return daily
            .filter { row in
                let day = calendar.startOfDay(for: row.day)
                return day >= from && day <= today
            }
            .reduce(0) { $0 + $1.totalCost }
    }
}

/// The Overview's CLI card (spec § Screens, "Overview"): today's dollars from the local
/// log, the turns and tokens behind them, the last 7 and 30 days, and the way to History.
/// The dollars are API-list-price equivalents, and the card says so (`CostCopy`).
struct OverviewCLICard: View {
    /// "Claude Code CLI · today".
    let title: String
    let cli: CLIBreakdown?
    let isLoading: Bool
    /// `CostCopy`'s API-equivalent sentence; nil for pay-as-you-go.
    let caption: String?
    let onHistory: () -> Void

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: OverviewCLIRules.spacing) {
            VStack(alignment: .leading, spacing: OverviewCLIRules.headSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: OverviewCLIRules.titleSize, weight: .semibold))
                        .foregroundStyle(.om(.secondary))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(OverviewLink.history.title, action: onHistory)
                        .buttonStyle(.omLink)
                }
                if let cli {
                    Text(OMCostTile.money(cli.todayCost))
                        .font(OMFont.numerals(size: OverviewCLIRules.headlineSize, weight: .bold))
                        .tracking(OverviewCLIRules.headlineTracking)
                        .foregroundStyle(.om(.text))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(OverviewCopy.todayLine(turns: cli.todayTurns, tokens: cli.todayTokens))
                        .font(.system(size: OverviewCLIRules.todayLineSize))
                        .foregroundStyle(.om(.secondary))
                }
            }
            if let cli {
                OverviewDayBarsView(bars: OverviewCLIRules.bars(daily: cli.daily, now: now, calendar: .current))
                HStack(alignment: .top, spacing: OverviewCLIRules.figureSpacing) {
                    figure(
                        OverviewCopy.lastSevenDays,
                        OverviewCLIRules.cost(daily: cli.daily, lastDays: OverviewCLIRules.weekDays, now: now, calendar: .current)
                    )
                    figure(
                        OverviewCopy.lastThirtyDays,
                        OverviewCLIRules.cost(daily: cli.daily, lastDays: OverviewCLIRules.monthDays, now: now, calendar: .current)
                    )
                }
                if let caption {
                    Text(caption)
                        .font(.system(size: OverviewCLIRules.captionSize))
                        .foregroundStyle(.om(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(OverviewCopy.noCLIUsage)
                    .font(.system(size: OverviewCLIRules.todayLineSize))
                    .foregroundStyle(.om(.secondary))
            }
        }
        .padding(.top, OverviewCLIRules.topPadding)
        .padding(.horizontal, OverviewCLIRules.horizontalPadding)
        .padding(.bottom, OverviewCLIRules.bottomPadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardCard(padding: 0)
    }

    private func figure(_ label: String, _ dollars: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: OverviewCLIRules.figureLabelSize))
                .foregroundStyle(.om(.secondary))
            Text(OMCostTile.money(dollars))
                .font(OMFont.numerals(size: OverviewCLIRules.figureSize, weight: .semibold))
                .foregroundStyle(.om(.text))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 30-day bars

/// One day on the CLI card's 30-day strip.
struct OverviewDayBar: Equatable, Identifiable {
    /// How the bar is painted: the older days quiet, the week "Last 7 days" counts
    /// brighter, today in yolk.
    enum Tone: Equatable, Sendable {
        case older, lastWeek, today
    }

    let day: Date
    let cost: Double
    let turns: Int
    let tokens: Int
    let tone: Tone

    var id: Date { day }
}

extension OverviewCLIRules {
    static let barCount = 30
    static let barAreaHeight: CGFloat = 118
    static let barSpacing: CGFloat = 3
    static let barCorner: CGFloat = 3
    /// A day with any spend stays visible next to a big one.
    static let minimumBarHeight: CGFloat = 2
    static let axisSize: CGFloat = 11
    static let axisSpacing: CGFloat = 8

    /// Thirty calendar days ending today, oldest first, one bar each: the log's daily rows
    /// re-keyed to this calendar's days (a row folded at another zone's midnight lands on
    /// the day it falls in, and rows on one day add up), zero for a day with none.
    static func bars(daily: [CLIDailySummary], now: Date, calendar: Calendar) -> [OverviewDayBar] {
        var byDay: [Date: (cost: Double, turns: Int, tokens: Int)] = [:]
        for row in daily {
            let key = calendar.startOfDay(for: row.day)
            let kept = byDay[key] ?? (cost: 0, turns: 0, tokens: 0)
            byDay[key] = (
                cost: kept.cost + row.totalCost,
                turns: kept.turns + row.turns,
                tokens: TokenBreakdown.saturating(kept.tokens, row.totalTokens)
            )
        }
        let today = calendar.startOfDay(for: now)
        return (0..<barCount).compactMap { index -> OverviewDayBar? in
            let offset = index - (barCount - 1)
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let value = byDay[day] ?? (cost: 0, turns: 0, tokens: 0)
            let tone: OverviewDayBar.Tone = offset == 0 ? .today : (offset > -weekDays ? .lastWeek : .older)
            return OverviewDayBar(day: day, cost: value.cost, turns: value.turns, tokens: value.tokens, tone: tone)
        }
    }

    /// Each bar's height, scaled to the biggest day; a day with any spend is at least
    /// `minimumBarHeight`, a day with none draws nothing.
    static func barHeights(_ bars: [OverviewDayBar], maxHeight: CGFloat) -> [CGFloat] {
        let top = bars.map(\.cost).max() ?? 0
        guard top > 0 else { return bars.map { _ in 0 } }
        return bars.map { bar in
            bar.cost > 0 ? max(minimumBarHeight, maxHeight * CGFloat(bar.cost / top)) : 0
        }
    }

    /// The bar's paint: the track, twice the track, yolk.
    static func token(for tone: OverviewDayBar.Tone) -> OMColorToken {
        switch tone {
        case .older: return .track
        case .lastWeek: return .barRecent
        case .today: return .accent
        }
    }

    /// A bar's tooltip (spec § Components, "Chart tooltip"): its day, dollars, turns and
    /// tokens, in the words History's rows use; "no usage" for an empty day.
    static func tooltip(for bar: OverviewDayBar, calendar: Calendar, locale: Locale) -> String {
        let weekday = bar.day.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        )
        let date = "\(weekday) \(SessionCopy.dayText(bar.day, calendar: calendar, locale: locale))"
        guard bar.turns > 0 || bar.cost > 0 else { return "\(date) · no usage" }
        return "\(date) · \(SessionCopy.cost(bar.cost)) · \(SessionCopy.turns(bar.turns)) · \(TokenFormat.formatTokens(bar.tokens)) tokens"
    }
}

/// The CLI card's strip: a bar per day for thirty days, scaled to the biggest, the week
/// "Last 7 days" counts brighter and today in yolk. Hovering a bar names its day and
/// figures. VoiceOver skips it: the figures under it say the same in words.
struct OverviewDayBarsView: View {
    let bars: [OverviewDayBar]

    var body: some View {
        let heights = OverviewCLIRules.barHeights(bars, maxHeight: OverviewCLIRules.barAreaHeight)
        VStack(alignment: .leading, spacing: OverviewCLIRules.axisSpacing) {
            HStack(alignment: .bottom, spacing: OverviewCLIRules.barSpacing) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    RoundedRectangle(cornerRadius: OverviewCLIRules.barCorner, style: .continuous)
                        .fill(.om(OverviewCLIRules.token(for: bar.tone)))
                        .frame(maxWidth: .infinity)
                        .frame(height: heights[index])
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        // The whole column answers the pointer, not only a short bar.
                        .contentShape(Rectangle())
                        .help(OverviewCLIRules.tooltip(for: bar, calendar: .current, locale: .current))
                }
            }
            .frame(height: OverviewCLIRules.barAreaHeight)
            HStack {
                Text(OverviewCopy.axisStart)
                Spacer(minLength: 8)
                Text(OverviewCopy.axisEnd)
            }
            .font(.system(size: OverviewCLIRules.axisSize))
            .foregroundStyle(.om(.secondary))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - By model (spec § Decisions, "Overview by-model rows")

extension OverviewCLIRules {
    /// One model's line in `CLIBreakdown.byModelToday`: today's already, the aggregators
    /// cut it at the local day's start.
    typealias ModelEntry = (model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)

    /// One row of the card's "By model" block.
    struct ModelRow: Equatable, Identifiable {
        let model: String
        let tokens: Int
        let cost: Double

        var id: String { model }
    }

    /// The block lists at most this many models, as 2.7.1's rows did.
    static let modelRowLimit = 5

    /// Today's models by what they cost, dearest first, at most `limit`. Ties go to the
    /// name first in the alphabet: the models arrive from a dictionary, so equal costs
    /// would otherwise swap places between polls. A model that cost nothing is left out,
    /// and a day with no spend has no rows, so the card draws no block.
    static func modelRows(_ byModelToday: [ModelEntry], limit: Int = modelRowLimit) -> [ModelRow] {
        let rows = byModelToday
            .filter { $0.cost > 0 }
            .sorted { a, b in a.cost != b.cost ? a.cost > b.cost : a.model < b.model }
            .map { ModelRow(model: $0.model, tokens: $0.tokens, cost: $0.cost) }
        return Array(rows.prefix(max(0, limit)))
    }
}
