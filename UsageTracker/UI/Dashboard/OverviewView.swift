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
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Weekly limits are temporarily +50%")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Bonus ends \(endsAt.formatted(date: .complete, time: .omitted))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
                    .padding(.horizontal, 24)
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

        return VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold))
            BarSegment(percent: percent, height: 6, showsLabel: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var todayCard: some View {
        let cli = dashboard.cliBreakdown
        let cost = cli?.todayCost ?? 0
        let turns = cli?.todayTurns ?? 0
        let tokens = cli?.todayTokens ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Text("Today's CLI usage")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(turns) turn\(turns == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text("\(formatTokens(tokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func bucketsBlock(claude: ServiceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage windows")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            ForEach(claude.buckets) { b in
                HStack {
                    Text(b.label).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("resets \(formatRelative(b.resetsAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                BarSegment(percent: b.clampedPercent, height: 10, showsLabel: true)
                    .padding(.bottom, 4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private func cliBlock(cli: CLIBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude Code CLI")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
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
                        Text(entry.model).font(.system(size: 11))
                        Spacer()
                        Text(String(format: "$%.2f", entry.cost))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private func stat(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
            if let sub { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary) }
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
