import SwiftUI

struct OverviewView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dashboard: DashboardState

    private var claude: ServiceSnapshot? {
        appState.snapshot.services.first(where: { $0.id == "claude" })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: claude?.displayName ?? "Claude",
                    subtitle: claude?.plan ?? "—"
                )

                if case .active(let endsAt) = Announcements.weeklyBonus() {
                    banner(
                        icon: "sparkles", tint: .green,
                        title: "Weekly limits are temporarily +50%",
                        subtitle: "Bonus ends \(endsAt.formatted(date: .complete, time: .omitted))"
                    )
                }
                if case .active(let endsAt) = Announcements.fableIncluded() {
                    banner(
                        icon: "wand.and.stars", tint: .purple,
                        title: "Fable 5 is included with your plan",
                        subtitle: "From \(endsAt.formatted(date: .abbreviated, time: .omitted)) it will draw extra-usage credits"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    burnCard(title: "5-hour burn rate", burn: dashboard.burnFiveHour, bucketId: "five_hour")
                    todayCard
                }
                .padding(.horizontal, 24)

                if let claude {
                    bucketsBlock(claude: claude)
                        .padding(.horizontal, 24)
                }

                if let cli = dashboard.cliBreakdown {
                    cliBlock(cli: cli)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func banner(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .bannerCard(tint: tint)
        .padding(.horizontal, 24)
    }

    private func burnCard(title: String, burn: BurnRatePrediction?, bucketId: String) -> some View {
        let value: String = {
            guard let burn else { return "Not enough data" }
            guard let secs = burn.secondsToLimit else {
                if burn.percentPerMinute > 0 { return "Stable" }
                return "Idle"
            }
            return "Hit limit in \(formatDuration(secs))"
        }()

        let percent: Double = {
            guard let claude else { return 0 }
            return claude.buckets.first(where: { $0.id == bucketId })?.clampedPercent ?? 0
        }()

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
            UsageRing(percent: percent, size: 48)
        }
        .dashboardCard(padding: 14)
    }

    private var todayCard: some View {
        let cli = dashboard.cliBreakdown
        let cost = cli?.todayCost ?? 0
        let turns = cli?.todayTurns ?? 0
        let tokens = cli?.todayTokens ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("Today's CLI usage")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", cost))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(turns) turn\(turns == 1 ? "" : "s")")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text("\(formatTokens(tokens)) tokens")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .dashboardCard(padding: 14)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func bucketsBlock(claude: ServiceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage windows".uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(claude.buckets) { b in
                HStack {
                    Text(b.label).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("resets \(formatRelative(b.resetsAt))").font(.caption).foregroundStyle(.secondary)
                }
                BarSegment(percent: b.clampedPercent, height: 8, showsLabel: true)
                    .padding(.bottom, 4)
            }
        }
        .dashboardCard()
    }

    private func cliBlock(cli: CLIBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code CLI".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                if dashboard.isLoadingCLI {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 24) {
                stat(label: "Today", value: String(format: "$%.2f", cli.todayCost), sub: "\(cli.todayTurns) turns")
                stat(label: "7d", value: String(format: "$%.2f", cli.weekCost), sub: nil)
                stat(label: "30d", value: String(format: "$%.2f", cli.monthCost), sub: nil)
            }
            if !cli.byModelToday.isEmpty {
                Divider()
                ForEach(cli.byModelToday.prefix(5), id: \.model) { entry in
                    HStack {
                        Text(entry.model).font(.subheadline)
                        Spacer()
                        Text(String(format: "$%.2f", entry.cost))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .dashboardCard()
    }

    private func stat(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let sub { Text(sub).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let s = max(0, secs)
        let h = Int(s / 3600)
        let m = Int((s.truncatingRemainder(dividingBy: 3600)) / 60)
        if h > 24 {
            let d = h / 24
            let rh = h % 24
            return "\(d)d \(rh)h"
        }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func formatRelative(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        if delta <= 0 || date >= Date.distantFuture.addingTimeInterval(-1) { return "—" }
        return "in \(formatDuration(delta))"
    }
}
