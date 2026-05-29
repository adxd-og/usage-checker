import SwiftUI

struct InsightsView: View {
    @ObservedObject var dashboard: DashboardState

    private var insights: Insights {
        Insights(from: dashboard.cliBreakdown, history: dashboard.history)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: "Insights",
                    subtitle: "Patterns from your usage data"
                )

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
                    card(
                        title: "5h window observed peak",
                        value: insights.fiveHourPeak.map { String(format: "%.0f%%", min(100, $0)) } ?? "—",
                        sub: "from snapshots"
                    )
                }
                .padding(.horizontal, 24)

                if let projects = dashboard.cliBreakdown?.projectsMonth, !projects.isEmpty {
                    projectsBlock(projects: projects)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func weekOverWeekCard(_ wow: WeekOverWeek) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This week vs last week")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", wow.thisWeek))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let delta = wow.deltaPercent, wow.lastWeek > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(abs(Int(delta.rounded())))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(delta >= 0 ? Color.orange : Color.green)
                }
            }
            HStack(spacing: 4) {
                Text("Last week: " + String(format: "$%.2f", wow.lastWeek))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func card(title: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .truncationMode(.tail)
            if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func projectsBlock(projects: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects · last 30 days")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(projects.count) total")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            let maxCost = projects.first?.totalCost ?? 1
            ForEach(projects.prefix(10)) { p in
                projectRow(p, maxCost: maxCost)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private func projectRow(_ p: ProjectSummary, maxCost: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "$%.2f", p.totalCost))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [.accentColor, .cyan.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
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

private struct Insights {
    let avgDailyCost: Double?
    let activeDays: Int?
    let peakDay: (day: Date, cost: Double)?
    let topModel: (model: String, cost: Double)?
    let topProjectWeek: ProjectSummary?
    let fiveHourPeak: Double?
    let firstSnapshotAgo: String?
    let weekOverWeek: WeekOverWeek

    init(from cli: CLIBreakdown?, history: [HistoryRecord]) {
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
        self.fiveHourPeak = history.compactMap(\.fiveHourPercent).max()
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
