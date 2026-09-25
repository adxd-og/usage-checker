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
