import SwiftUI

struct OverviewView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dashboard: DashboardState

    private var service: ServiceSnapshot? {
        appState.snapshot.services.first(where: { $0.id == dashboard.selectedService })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DashboardHeader(
                    title: service?.displayName ?? dashboard.displayName(for: dashboard.selectedService),
                    subtitle: service?.plan ?? "—"
                )

                HStack(alignment: .top, spacing: 16) {
                    heroCard
                    if dashboard.costSource.hasBreakdown { todayCard }
                }
                .padding(.horizontal, 24)

                if let service {
                    bucketsBlock(service: service)
                        .padding(.horizontal, 24)
                }

                if dashboard.costSource.hasBreakdown, let cli = dashboard.cliBreakdown {
                    cliBlock(cli: cli)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// The provider tab's hero, reused verbatim: the session window when the provider
    /// has one, otherwise its most-constrained window, with the burn verdict under it.
    /// A provider with no windows at all (nothing polled yet) keeps the old burn-rate
    /// wording rather than showing an empty card.
    @ViewBuilder
    private var heroCard: some View {
        if let service, let hero = WindowRanking.detailHero(for: service) {
            OMHero(
                hero: hero,
                verdict: BurnVerdict.make(
                    burn: dashboard.sessionBurn,
                    sessionBuckets: service.buckets.filter { $0.kind == .session }
                )
            )
            .dashboardCard(padding: 14)
        } else {
            burnCard
        }
    }

    /// Titled after the window it actually predicts — with several providers a
    /// fixed "5-hour" was wrong for anyone whose leading window isn't five hours.
    private var burnCard: some View {
        let burn = dashboard.sessionBurn
        let bucket = dashboard.burnBucket
        let value: String = {
            guard let burn else { return "Not enough data" }
            guard let secs = burn.secondsToLimit else {
                if burn.percentPerMinute > 0 { return "Stable" }
                return "Idle"
            }
            return "Hit limit in \(formatDuration(secs))"
        }()

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(bucket.map { "\($0.label) burn rate" } ?? "Burn rate")
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
                Text(value).font(OMFont.bodyStrong)
            }
            Spacer()
            OMRing(percent: bucket?.clampedPercent ?? 0, size: .medium)
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
                .font(OMFont.body)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", cost))
                    .font(OMFont.heroNumeral)
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(turns) turn\(turns == 1 ? "" : "s")")
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
            }
            Text("\(formatTokens(tokens)) tokens")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
        }
        .dashboardCard(padding: 14)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func bucketsBlock(service: ServiceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            OMSectionHeader(title: "Usage windows")
            ForEach(service.buckets) { b in
                // Same wording as before ("resets in 2h 15m" / "resets —"), now on the
                // component: the label, the reset time and the bar are one row.
                OMKeyValueRow(
                    label: b.label,
                    value: "resets \(formatRelative(b.resetsAt))",
                    barPercent: b.clampedPercent
                )
            }
        }
        .dashboardCard()
    }

    private func cliBlock(cli: CLIBreakdown) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            HStack {
                OMSectionHeader(title: dashboard.costSource.shortName ?? "CLI")
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
                    OMKeyValueRow(label: entry.model, value: String(format: "$%.2f", entry.cost))
                }
            }
        }
        .dashboardCard()
    }

    private func stat(label: String, value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(OMFont.caption).foregroundStyle(.secondary)
            Text(value).font(OMFont.heroNumeral).monospacedDigit()
            if let sub { Text(sub).font(OMFont.caption).foregroundStyle(.tertiary) }
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
