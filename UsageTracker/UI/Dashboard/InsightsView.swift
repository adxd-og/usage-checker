import SwiftUI

struct InsightsView: View {
    @ObservedObject var dashboard: DashboardState

    // Rebuilt off the main actor only when the inputs actually change — the summary
    // reduces over every daily summary and the full history array, far too heavy to
    // re-run on each body evaluation (same pattern as ActivityGridView's GridCache).
    @State private var summary = InsightsSummary.empty

    /// Read on every body evaluation, so the day in it follows the clock (see
    /// `InsightsCacheKey`).
    private var cacheKey: InsightsCacheKey {
        InsightsRules.cacheKey(
            service: dashboard.selectedService,
            cliUpdatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            quotaBucketIDs: dashboard.quotaCoreBucketIDs,
            now: Date()
        )
    }

    @MainActor
    private func rebuildInsights() async {
        let started = cacheKey
        let cli = dashboard.cliBreakdown
        let history = dashboard.history
        let coreBucketIDs = dashboard.quotaCoreBucketIDs
        let hasCostLog = dashboard.costSource.hasBreakdown
        let now = Date()
        // One detached pass: every figure reads the same history array, and copying it
        // across two tasks doubles the cost of the expensive part.
        let built = await Task.detached(priority: .userInitiated) {
            InsightsRules.summary(
                cli: cli,
                history: history,
                coreBucketIDs: coreBucketIDs,
                hasCostLog: hasCostLog,
                now: now
            )
        }.value
        // See `DerivedCacheGate`: a pass for the provider just left must not replace
        // the new provider's cards when it finishes second.
        guard DerivedCacheGate.canPublish(
            started: started, current: cacheKey, cancelled: Task.isCancelled
        ) else { return }
        summary = built
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(title: "Insights")

                if let window = dashboard.sessionWindow {
                    sessionWindowBlock(window)
                        .padding(.horizontal, 24)
                }

                // Cost, projects and models come from the selected provider's own CLI
                // log. A provider without one gets the reason, not another provider's
                // spend under its name.
                if dashboard.costSource.hasBreakdown {
                    cliBlock
                        .padding(.horizontal, 24)
                } else {
                    quotaBlock
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .task(id: cacheKey) {
            await rebuildInsights()
        }
    }

    /// What a provider without a cost log can still be asked. On a subscription the
    /// quota is the bill, so these read as the cost cards' counterparts: how often the
    /// limit actually got in the way, how much of a window a day costs, when.
    private var quotaBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Quota over time")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach([InsightsFigure.daysAtLimit, .averageDailyPeak, .quotaPerDay, .busiestQuotaDay, .busiestHour]) { figure in
                    figureCard(figure)
                }
            }
            Text(dashboard.costSource.reason ?? "")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the dollars on this page are a bill: the selected provider as the last
    /// poll saw it, through `CostCopy`'s rule. nil for a pay-as-you-go account.
    private var costCaption: String? {
        CostCopy.apiEquivalentCaption(
            for: AppState.shared.snapshot.services.first(where: { $0.id == dashboard.selectedService })
        )
    }

    private var cliBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(dashboard.costSource.shortName ?? "CLI")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach([InsightsFigure.weekOverWeek, .daysAtLimit, .dailyAverage, .biggestDay, .mostUsedModelToday]) { figure in
                    figureCard(figure)
                }
            }
            if let caption = costCaption {
                Text(caption)
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        OMSectionHeader(title: text)
    }

    /// Answers "why is my session at 90%?" with what actually ran while the window
    /// filled. Dollars rank the work; they don't decompose the percentage — the two are
    /// measured in different units, and usage from the Claude apps never reaches the CLI
    /// logs at all. The empty state says so rather than implying nothing happened.
    private func sessionWindowBlock(_ window: WindowUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            OMSectionHeader(
                title: InsightsCopy.sessionWindowTitle,
                trailing: InsightsCopy.since(window.start)
            )

            if window.isEmpty {
                Text(InsightsCopy.emptySession(providerID: dashboard.selectedService))
                    .font(OMFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(InsightsCopy.money(window.cost))
                        .font(OMFont.heroNumeral)
                        .monospacedDigit()
                    Text(InsightsCopy.turns(window.turns))
                        .font(OMFont.caption)
                        .foregroundStyle(.tertiary)
                }

                if !window.models.isEmpty {
                    Text(window.models.prefix(3)
                        .map { "\($0.model) " + InsightsCopy.money($0.cost) }
                        .joined(separator: "  ·  "))
                        .font(OMFont.caption)
                        .foregroundStyle(.secondary)
                }

                let rows = InsightsRules.projectRows(window.projects)
                if !rows.isEmpty {
                    Text(InsightsCopy.byProject)
                        .font(OMFont.bodyStrong)
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        projectRow(row)
                    }
                }

                if let caption = costCaption {
                    Text(caption)
                        .font(OMFont.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .dashboardCard()
    }

    /// One figure on the 2.x card: title, value with This week vs last's change beside
    /// it, caption.
    private func figureCard(_ figure: InsightsFigure) -> some View {
        let text = InsightsCopy.text(for: figure, summary: summary, quotaBuckets: dashboard.quotaBuckets)
        return VStack(alignment: .leading, spacing: 6) {
            Text(text.title).font(OMFont.body).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text.value)
                    .font(OMFont.heroNumeral)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let delta = text.delta {
                    // A direction, not a verdict: more spend than last week is not the
                    // same thing as being close to a limit.
                    Text(delta)
                        .font(OMFont.bodyStrong)
                        .monospacedDigit()
                        .foregroundStyle(.om(.accentText))
                }
            }
            if let caption = text.caption {
                Text(caption).font(OMFont.caption).foregroundStyle(.tertiary)
            }
        }
        .dashboardCard()
    }

    private func projectRow(_ row: InsightsProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name)
                    .font(OMFont.bodyStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(InsightsCopy.money(row.cost))
                    .font(OMFont.numeral)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.quaternary)
                        // Dollars, not utilisation: the accent colour, never the
                        // battery ramp — a big spend is not a warning.
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(row.fraction))
                    }
                }
                .frame(height: 6)

                Text(InsightsCopy.turns(row.turns))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .help(row.id)
    }
}

struct WeekOverWeek: Equatable, Sendable {
    let thisWeek: Double
    let lastWeek: Double
    let deltaPercent: Double?

    static let empty = WeekOverWeek(thisWeek: 0, lastWeek: 0, deltaPercent: nil)

    init(thisWeek: Double, lastWeek: Double) {
        self.thisWeek = thisWeek
        self.lastWeek = lastWeek
        if lastWeek > 0 {
            self.deltaPercent = (thisWeek - lastWeek) / lastWeek * 100.0
        } else {
            self.deltaPercent = nil
        }
    }

    init(thisWeek: Double, lastWeek: Double, deltaPercent: Double?) {
        self.thisWeek = thisWeek
        self.lastWeek = lastWeek
        self.deltaPercent = deltaPercent
    }
}

extension InsightsView {
    /// The dearest day of the ninety this card has always covered.
    ///
    /// `CLIBreakdown.daily` reaches back a year now, because the Activity cards need
    /// it to; "Biggest day" does not, and it carries no range in its title, so a peak
    /// from last autumn would be a change of meaning rather than more information.
    /// The cutoff is the Activity 90-day card's, so the two can never drift apart.
    nonisolated static func peakDay(
        in dailies: [CLIDailySummary],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (day: Date, cost: Double)? {
        let cutoff = ActivityCardRule.cutoffs(now: now, calendar: calendar).ninety
        guard let peak = dailies
            .filter({ $0.day >= cutoff })
            .max(by: { $0.totalCost < $1.totalCost }),
            peak.totalCost > 0
        else { return nil }
        return (peak.day, peak.totalCost)
    }
}
