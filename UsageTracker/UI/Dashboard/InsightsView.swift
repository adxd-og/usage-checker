import SwiftUI

/// Dashboard → Insights (liquid-glass spec § Screens, "Insights";
/// `Dashboard-Insights(-Light).dc.html`): what ran in the open session window, this
/// week against last, how many of the last seven days hit a limit, and a strip of three
/// figures. The cards are `InsightsRules.page`'s, their words `InsightsCopy.text`'s, the
/// first row's split `InsightsLayout.topRow`'s and every measure `InsightsMetrics`'.
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

    /// The cards the selected provider gets, in the mockup's order.
    private var page: InsightsPage {
        InsightsRules.page(
            hasCostLog: dashboard.costSource.hasBreakdown,
            hasSessionWindow: dashboard.sessionWindow != nil
        )
    }

    /// The selected provider as the last poll saw it: whether its dollars are a bill.
    private var selectedSnapshot: ServiceSnapshot? {
        AppState.shared.snapshot.services.first(where: { $0.id == dashboard.selectedService })
    }

    var body: some View {
        // Measured once, off the width the tab is given, as History does: the first row
        // and everything in it draw to one decision.
        GeometryReader { proxy in
            let contentWidth = proxy.size.width
                - DashboardShellLayout.columnLeading
                - DashboardShellLayout.columnTrailing
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DashboardHeader(title: "Insights")
                    content(contentWidth: contentWidth)
                        .padding(.top, InsightsMetrics.headerGap)
                        .padding(.leading, DashboardShellLayout.columnLeading)
                        .padding(.trailing, DashboardShellLayout.columnTrailing)
                        .padding(.bottom, InsightsMetrics.columnBottom)
                }
            }
        }
        .task(id: cacheKey) {
            await rebuildInsights()
        }
    }

    private func content(contentWidth: CGFloat) -> some View {
        let page = self.page
        return VStack(alignment: .leading, spacing: InsightsMetrics.gap) {
            topRow(page: page, contentWidth: contentWidth)
            strip(page.strip)
            // Once per page, under everything: what the dollars are, or why a provider
            // has none.
            if let footnote = InsightsRules.footnote(
                costSource: dashboard.costSource, service: selectedSnapshot
            ) {
                Text(footnote)
                    .font(.system(size: InsightsMetrics.footnoteSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - First row

    @ViewBuilder
    private func topRow(page: InsightsPage, contentWidth: CGFloat) -> some View {
        if page.showsSessionWindow, let window = dashboard.sessionWindow {
            switch InsightsLayout.topRow(contentWidth: contentWidth) {
            case let .sideBySide(sessionWidth, cardsWidth):
                HStack(alignment: .top, spacing: InsightsMetrics.gap) {
                    sessionWindowCard(window)
                        .frame(width: sessionWidth)
                    VStack(spacing: InsightsMetrics.gap) {
                        ForEach(page.cards) { figure in
                            figureCard(figure)
                        }
                    }
                    .frame(width: cardsWidth)
                }
                // One height for both columns: the figure cards share the session
                // window's, as the mockup's grid row stretches them.
                .fixedSize(horizontal: false, vertical: true)
            case .stacked:
                VStack(alignment: .leading, spacing: InsightsMetrics.gap) {
                    sessionWindowCard(window)
                    cardsRow(page.cards)
                }
            }
        } else {
            cardsRow(page.cards)
        }
    }

    /// The figure cards side by side, at equal widths and one height.
    private func cardsRow(_ figures: [InsightsFigure]) -> some View {
        HStack(alignment: .top, spacing: InsightsMetrics.gap) {
            ForEach(figures) { figure in
                figureCard(figure)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Figures

    /// One figure on its own card, centred in the card's height.
    private func figureCard(_ figure: InsightsFigure) -> some View {
        figureBlock(figure, valueSize: InsightsMetrics.cardValueSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .insightsCard(
                vertical: InsightsMetrics.figureCardVerticalPadding,
                horizontal: InsightsMetrics.figureCardHorizontalPadding
            )
    }

    /// The mockup's strip: figures in equal columns, a hairline between neighbours.
    private func strip(_ figures: [InsightsFigure]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(figures.enumerated()), id: \.element) { index, figure in
                if index > 0 {
                    Rectangle()
                        .fill(.om(.hairline))
                        .frame(width: InsightsMetrics.stripDividerWidth)
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, InsightsMetrics.stripColumnGap)
                        .accessibilityHidden(true)
                }
                figureBlock(figure, valueSize: InsightsMetrics.stripValueSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .insightsCard(
            vertical: InsightsMetrics.stripVerticalPadding,
            horizontal: InsightsMetrics.stripHorizontalPadding
        )
    }

    /// Title, value (This week vs last's change beside it), caption: one figure as the
    /// mockup draws it on a card and in the strip alike.
    private func figureBlock(_ figure: InsightsFigure, valueSize: CGFloat) -> some View {
        let text = InsightsCopy.text(for: figure, summary: summary, quotaBuckets: dashboard.quotaBuckets)
        return VStack(alignment: .leading, spacing: InsightsMetrics.figureSpacing) {
            Text(text.title)
                .font(.system(size: InsightsMetrics.figureTitleSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: InsightsMetrics.deltaSpacing) {
                Text(text.value)
                    .font(OMFont.numerals(size: valueSize, weight: .bold))
                    .tracking(InsightsMetrics.figureValueTracking)
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
                    .minimumScaleFactor(InsightsMetrics.valueMinimumScale)
                if let delta = text.delta {
                    // A direction, not a verdict: more spend than last week is not the
                    // same thing as being close to a limit.
                    Text(delta)
                        .font(.system(size: InsightsMetrics.deltaSize, weight: .semibold))
                        .foregroundStyle(.om(.accentText))
                        .lineLimit(1)
                }
            }
            if let caption = text.caption {
                Text(caption)
                    .font(.system(size: InsightsMetrics.figureCaptionSize))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Session window

    /// What ran while the session window filled. Dollars rank the work; they don't
    /// decompose the percentage — the two are measured in different units, and usage
    /// from the Claude apps never reaches the CLI logs at all. The empty state says so
    /// rather than implying nothing happened.
    private func sessionWindowCard(_ window: WindowUsage) -> some View {
        VStack(alignment: .leading, spacing: InsightsMetrics.sessionSpacing) {
            sessionHeader(window)
            if window.isEmpty {
                Text(InsightsCopy.emptySession(providerID: dashboard.selectedService))
                    .font(.system(size: InsightsMetrics.figureCaptionSize))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                sessionTotal(window)
                let shares = InsightsRules.modelSplit(window.models)
                if !shares.isEmpty {
                    modelSplitBar(shares)
                    modelLegend(shares)
                }
                let rows = InsightsRules.projectRows(window.projects)
                if !rows.isEmpty {
                    projectList(rows)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insightsCard(
            vertical: InsightsMetrics.sessionCardVerticalPadding,
            horizontal: InsightsMetrics.sessionCardHorizontalPadding
        )
    }

    /// "Current session window" with "since 10:30" on its baseline.
    private func sessionHeader(_ window: WindowUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InsightsMetrics.sessionHeaderSpacing) {
            Text(InsightsCopy.sessionWindowTitle)
                .font(.system(size: InsightsMetrics.sessionTitleSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: InsightsMetrics.sessionHeaderSpacing)
            Text(InsightsCopy.since(window.start))
                .font(.system(size: InsightsMetrics.sessionTrailingSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
        }
    }

    /// The window's dollars and turns.
    private func sessionTotal(_ window: WindowUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: InsightsMetrics.sessionValueSpacing) {
            Text(InsightsCopy.money(window.cost))
                .font(OMFont.numerals(size: InsightsMetrics.sessionValueSize, weight: .bold))
                .tracking(InsightsMetrics.sessionValueTracking)
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .minimumScaleFactor(InsightsMetrics.valueMinimumScale)
            Text(InsightsCopy.turns(window.turns))
                .font(.system(size: InsightsMetrics.sessionTurnsSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The window's dollars by model: one segment per model, `splitBarGap` apart, in a
    /// bar with rounded ends.
    private func modelSplitBar(_ shares: [InsightsModelShare]) -> some View {
        GeometryReader { geo in
            let gaps = InsightsMetrics.splitBarGap * CGFloat(max(shares.count - 1, 0))
            let available = max(geo.size.width - gaps, 0)
            HStack(spacing: InsightsMetrics.splitBarGap) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    Rectangle()
                        .fill(.om(InsightsMetrics.splitToken(for: share, at: index)))
                        .frame(width: available * share.fraction)
                }
            }
        }
        .frame(height: InsightsMetrics.splitBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: InsightsMetrics.splitBarRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Dot, name and dollars per model, on one line where they fit and stacked where
    /// the card is too narrow.
    private func modelLegend(_ shares: [InsightsModelShare]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: InsightsMetrics.legendSpacing) {
                legendItems(shares)
            }
            VStack(alignment: .leading, spacing: InsightsMetrics.legendItemSpacing) {
                legendItems(shares)
            }
        }
    }

    @ViewBuilder
    private func legendItems(_ shares: [InsightsModelShare]) -> some View {
        ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
            HStack(spacing: InsightsMetrics.legendItemSpacing) {
                Circle()
                    .fill(.om(InsightsMetrics.splitToken(for: share, at: index)))
                    .frame(width: InsightsMetrics.legendDotSize, height: InsightsMetrics.legendDotSize)
                Text(share.model)
                    .font(.system(size: InsightsMetrics.legendTextSize))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(1)
                Text(InsightsCopy.money(share.cost))
                    .font(OMFont.numerals(size: InsightsMetrics.legendTextSize, weight: .semibold))
                    .foregroundStyle(.om(.text))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "By project" and the rows under it, a hairline between two rows.
    private func projectList(_ rows: [InsightsProjectRow]) -> some View {
        VStack(alignment: .leading, spacing: InsightsMetrics.sessionSpacing) {
            Text(InsightsCopy.byProject)
                .font(.system(size: InsightsMetrics.byProjectSize, weight: .semibold))
                .foregroundStyle(.om(.secondary))
                .padding(.top, InsightsMetrics.byProjectTopPadding)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    projectRow(row)
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle()
                                    .fill(.om(.hairline))
                                    .frame(height: InsightsMetrics.projectDividerHeight)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
        }
    }

    /// Name · bar against the dearest project · dollars · turns: the mockup's
    /// `170px 1fr 90px 80px` grid.
    private func projectRow(_ row: InsightsProjectRow) -> some View {
        HStack(spacing: InsightsMetrics.projectColumnGap) {
            Text(row.name)
                .font(.system(size: InsightsMetrics.projectNameSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: InsightsMetrics.projectNameWidth, alignment: .leading)
            // Dollars, not utilisation: the accent, never the gauge ramp — a big spend
            // is not a warning.
            Capsule(style: .continuous)
                .fill(.om(.track))
                .frame(height: InsightsMetrics.projectBarHeight)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule(style: .continuous)
                            .fill(.om(.accent))
                            .frame(width: geo.size.width * row.fraction)
                    }
                }
                .frame(maxWidth: .infinity)
            Text(InsightsCopy.money(row.cost))
                .font(OMFont.numerals(size: InsightsMetrics.projectCostSize, weight: .semibold))
                .foregroundStyle(.om(.text))
                .lineLimit(1)
                .frame(width: InsightsMetrics.projectCostWidth, alignment: .trailing)
            Text(InsightsCopy.turns(row.turns))
                .font(.system(size: InsightsMetrics.projectTurnsSize))
                .foregroundStyle(.om(.secondary))
                .lineLimit(1)
                .frame(width: InsightsMetrics.projectTurnsWidth, alignment: .trailing)
        }
        .padding(.vertical, InsightsMetrics.projectRowVerticalPadding)
        .help(row.id)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// `dashboardCard(padding:)` pads all four sides alike; the mockup's cards pad their
    /// sides more than their top and bottom, so the difference goes on first.
    func insightsCard(vertical: CGFloat, horizontal: CGFloat) -> some View {
        padding(.horizontal, horizontal - vertical)
            .dashboardCard(padding: vertical)
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
