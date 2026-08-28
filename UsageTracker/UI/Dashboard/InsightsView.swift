import SwiftUI

struct InsightsView: View {
    @ObservedObject var dashboard: DashboardState

    // Rebuilt off the main actor only when the inputs actually change — the
    // init reduces over every daily summary and the full history array, far
    // too heavy to re-run on each body evaluation (same pattern as
    // ActivityGridView's GridCache).
    @State private var insights = Insights.empty
    /// The quota half — what a provider with no cost log can still say about itself.
    @State private var quota = QuotaInsights.empty

    private struct CacheKey: Hashable {
        let service: String
        let cliUpdatedAt: Date
        let historyCount: Int
        let lastHistoryAt: Date
        let peakBucketID: String?
        let quotaBucketIDs: [String]
    }

    private var cacheKey: CacheKey {
        CacheKey(
            service: dashboard.selectedService,
            cliUpdatedAt: dashboard.cliBreakdown?.updatedAt ?? .distantPast,
            historyCount: dashboard.history.count,
            lastHistoryAt: dashboard.history.last?.timestamp ?? .distantPast,
            peakBucketID: dashboard.burnBucket?.id,
            quotaBucketIDs: dashboard.quotaCoreBucketIDs
        )
    }

    @MainActor
    private func rebuildInsights() async {
        let cli = dashboard.cliBreakdown
        let history = dashboard.history
        let peakBucketID = dashboard.burnBucket?.id
        // Empty for a provider whose cost log is showing, which short-circuits the quota
        // pass entirely: Claude has months of history across half a dozen windows, and
        // walking all of it every poll to fill cards nobody sees is pure waste.
        let quotaBucketIDs = dashboard.costSource.hasBreakdown ? [] : dashboard.quotaCoreBucketIDs
        // Both halves in one detached pass: they read the same history array, and
        // copying it across two tasks doubles the cost of the expensive part.
        let built = await Task.detached(priority: .userInitiated) {
            (
                Insights(from: cli, history: history, peakBucketID: peakBucketID),
                QuotaAnalytics.insights(records: history, bucketIDs: quotaBucketIDs)
            )
        }.value
        insights = built.0
        quota = built.1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: "Insights",
                    subtitle: "Patterns from your usage data"
                )

                if let window = dashboard.sessionWindow {
                    sessionWindowBlock(window)
                        .padding(.horizontal, 24)
                }

                usageBlock
                    .padding(.horizontal, 24)

                // Cost, projects and models come from the selected provider's own CLI
                // log. A provider without one gets the reason, not another provider's
                // spend under its name.
                if dashboard.costSource.hasBreakdown {
                    cliBlock
                        .padding(.horizontal, 24)

                    if let projects = dashboard.cliBreakdown?.projectsMonth, !projects.isEmpty {
                        projectsBlock(projects: projects)
                            .padding(.horizontal, 24)
                    }
                } else {
                    quotaBlock
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task(id: cacheKey) {
            await rebuildInsights()
        }
    }

    /// The half that follows the provider picker: everything here is derived from
    /// the selected provider's own usage snapshots.
    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(dashboard.displayName(for: dashboard.selectedService) + " · usage history")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                card(
                    title: (dashboard.burnBucket?.label ?? "Window") + " observed peak",
                    value: insights.windowPeak.map { String(format: "%.0f%%", min(100, $0)) } ?? "—",
                    sub: "from snapshots"
                )
                card(
                    title: "Snapshots recorded",
                    value: "\(insights.snapshotCount)",
                    sub: insights.firstSnapshotAgo
                )
            }
        }
    }

    /// What a provider without a cost log can still be asked. On a subscription the
    /// quota is the bill, so these read as the cost cards' counterparts: how often the
    /// limit actually got in the way, how much of a window a day costs, when.
    private var quotaBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Quota over time")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                card(
                    title: "Days at capacity",
                    value: "\(quota.daysAtCapacity)",
                    sub: "of \(quota.daysObserved) days recorded"
                )
                card(
                    title: "Average daily peak",
                    value: quota.averageDailyPeak.map { String(format: "%.0f%%", $0) } ?? "—",
                    sub: quota.todayPeak.map { String(format: "%.0f%% so far today", $0) }
                )
                card(
                    title: "Quota used per day",
                    value: quota.averageDailyConsumption.map { String(format: "%.0f%%", $0) } ?? "—",
                    sub: "of a window, resets counted"
                )
                card(
                    title: "Busiest day",
                    value: quota.busiestDay.map { String(format: "%.0f%%", $0.peak) } ?? "—",
                    sub: quota.busiestDay.map { busiestDaySubtitle($0) }
                )
                card(
                    title: "Busiest hour",
                    value: quota.busiestHour.map(formatHour) ?? "—",
                    sub: "when the quota climbs most"
                )
            }
            Text(dashboard.costSource.reason ?? "")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func busiestDaySubtitle(_ peak: DailyPeak) -> String {
        let label = dashboard.quotaBuckets.first(where: { $0.id == peak.peakBucketID })?.label
            ?? QuotaAnalytics.prettifiedLabel(for: peak.peakBucketID)
        return "\(peak.day.formatted(date: .abbreviated, time: .omitted)) · \(label)"
    }

    /// Rendered through the user's own clock format — "14:00" is the wrong answer on a
    /// machine that shows 2 PM everywhere else.
    private func formatHour(_ hour: Int) -> String {
        let cal = Calendar.current
        guard let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else {
            return String(format: "%02d:00", hour)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var cliBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(dashboard.costSource.shortName ?? "CLI")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                weekOverWeekCard(insights.weekOverWeek)
                card(
                    title: "Daily average (30d)",
                    value: insights.avgDailyCost.map { String(format: "$%.2f", $0) } ?? "—",
                    sub: insights.activeDays.map { "\($0) active days" }
                )
                card(
                    title: "Biggest day",
                    value: insights.peakDay.map { String(format: "$%.2f", $0.cost) } ?? "—",
                    sub: insights.peakDay.map { $0.day.formatted(date: .abbreviated, time: .omitted) }
                )
                card(
                    title: "Most-used model",
                    value: insights.topModel?.model ?? "—",
                    sub: insights.topModel.map { String(format: "$%.2f today", $0.cost) }
                )
                card(
                    title: "Top project this week",
                    value: insights.topProjectWeek?.displayName ?? "—",
                    sub: insights.topProjectWeek.map { String(format: "$%.2f · %d turns", $0.totalCost, $0.turns) }
                )
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }

    /// Answers "why is my session at 90%?" with what actually ran while the window
    /// filled. Dollars rank the work; they don't decompose the percentage — the two are
    /// measured in different units, and usage from the Claude apps never reaches the CLI
    /// logs at all. The empty state says so rather than implying nothing happened.
    private func sessionWindowBlock(_ window: WindowUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Current session window")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("since \(window.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if window.isEmpty {
                Text("No Claude Code activity in this window. Whatever the session limit is showing came from somewhere else — the Claude apps, or another machine on this account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "$%.2f", window.cost))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("\(window.turns) turns")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !window.models.isEmpty {
                    Text(window.models.prefix(3)
                        .map { "\($0.model) " + String(format: "$%.2f", $0.cost) }
                        .joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let maxCost = window.projects.first?.totalCost ?? 1
                ForEach(window.projects.prefix(5)) { project in
                    projectRow(project, maxCost: maxCost)
                }
            }
        }
        .dashboardCard()
    }

    private func weekOverWeekCard(_ wow: WeekOverWeek) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This week vs last week")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", wow.thisWeek))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let delta = wow.deltaPercent, wow.lastWeek > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(abs(Int(delta.rounded())))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(delta >= 0 ? Color.orange : Color.green)
                }
            }
            HStack(spacing: 4) {
                Text("Last week: " + String(format: "$%.2f", wow.lastWeek))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .dashboardCard()
    }

    private func card(title: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
            if let sub { Text(sub).font(.caption).foregroundStyle(.tertiary) }
        }
        .dashboardCard()
    }

    private func projectsBlock(projects: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects · last 30 days")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(projects.count) total")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            let maxCost = projects.first?.totalCost ?? 1
            ForEach(projects.prefix(10)) { p in
                projectRow(p, maxCost: maxCost)
            }
        }
        .dashboardCard()
    }

    private func projectRow(_ p: ProjectSummary, maxCost: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "$%.2f", p.totalCost))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.quaternary)
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(p.totalCost / max(maxCost, 0.01)))
                    }
                }
                .frame(height: 6)

                Text("\(p.turns) turn\(p.turns == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .help(p.slug)
    }
}

struct WeekOverWeek {
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

private struct Insights: Sendable {
    static let empty = Insights(from: nil, history: [], peakBucketID: nil)

    let avgDailyCost: Double?
    let activeDays: Int?
    let peakDay: (day: Date, cost: Double)?
    let topModel: (model: String, cost: Double)?
    let topProjectWeek: ProjectSummary?
    /// Highest utilization ever observed for the provider's leading window.
    let windowPeak: Double?
    let snapshotCount: Int
    let firstSnapshotAgo: String?
    let weekOverWeek: WeekOverWeek

    init(from cli: CLIBreakdown?, history: [HistoryRecord], peakBucketID: String?) {
        let dailies = cli?.daily ?? []
        let last30 = dailies.filter { $0.day >= Date().addingTimeInterval(-30 * 24 * 3600) }
        let active = last30.filter { $0.totalCost > 0 }
        self.activeDays = active.count
        self.avgDailyCost = active.isEmpty ? nil : active.map(\.totalCost).reduce(0, +) / Double(active.count)
        if let p = dailies.max(by: { $0.totalCost < $1.totalCost }), p.totalCost > 0 {
            self.peakDay = (p.day, p.totalCost)
        } else {
            self.peakDay = nil
        }
        if let top = cli?.byModelToday.first {
            self.topModel = (top.model, top.cost)
        } else {
            self.topModel = nil
        }
        self.topProjectWeek = cli?.projectsWeek.first
        self.snapshotCount = history.count
        // Keyed on whichever window the provider actually leads with — a fixed
        // "five_hour" read as "—" for every provider that doesn't have one.
        self.windowPeak = peakBucketID.flatMap { id in
            history.compactMap { $0.percent(for: id) }.max()
        }
        if let first = history.first {
            let delta = Date().timeIntervalSince(first.timestamp)
            let days = Int(delta / (24 * 3600))
            if days >= 1 { self.firstSnapshotAgo = "since \(days)d ago" }
            else { self.firstSnapshotAgo = "since today" }
        } else {
            self.firstSnapshotAgo = nil
        }

        // Week-over-week (rolling 7d): "this week" = last 7 days, "last week" = days [-14..-7).
        let now = Date()
        let last7Cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        let last14Cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let thisWeek = dailies.filter { $0.day >= last7Cutoff }.map(\.totalCost).reduce(0, +)
        let lastWeek = dailies.filter { $0.day >= last14Cutoff && $0.day < last7Cutoff }.map(\.totalCost).reduce(0, +)
        self.weekOverWeek = WeekOverWeek(thisWeek: thisWeek, lastWeek: lastWeek)
    }
}
