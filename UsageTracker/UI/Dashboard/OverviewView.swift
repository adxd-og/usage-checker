import SwiftUI

struct OverviewView: View {
    @ObservedObject var appState: AppState
    /// Observed, so the switch repaints an open dashboard rather than waiting for
    /// the next poll.
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var dashboard: DashboardState

    private var service: ServiceSnapshot? {
        appState.snapshot.services.first(where: { $0.id == dashboard.selectedService })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The age ticks every five seconds, as the sidebar footnote's does.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    DashboardHeader(
                        title: service?.displayName ?? dashboard.displayName(for: dashboard.selectedService),
                        subtitle: OverviewCopy.subtitle(
                            service: service,
                            snapshotFetchedAt: appState.snapshot.fetchedAt,
                            now: context.date
                        )
                    )
                }

                VStack(alignment: .leading, spacing: OverviewLayout.spacing) {
                    OverviewColumns {
                        heroCard
                        if OverviewLayout.showsCLICard(hasBreakdown: dashboard.costSource.hasBreakdown) {
                            todayCard
                        }
                    }

                    // Under the cards and above the CLI dollars: the same log's data, one
                    // question earlier ("what did those tokens do?").
                    if OverviewLayout.showsTokensCard(
                        hasBreakdown: dashboard.costSource.hasBreakdown,
                        todayTokens: dashboard.cliBreakdown?.todayTokenBreakdown.total ?? 0
                    ), let cli = dashboard.cliBreakdown {
                        TokensTodayCard(breakdown: cli.todayTokenBreakdown)
                    }

                    if dashboard.costSource.hasBreakdown, let cli = dashboard.cliBreakdown {
                        cliBlock(cli: cli)
                    }
                }
                .padding(.top, OverviewLayout.contentTop)
                .padding(.leading, DashboardShellLayout.columnLeading)
                .padding(.trailing, DashboardShellLayout.columnTrailing)
                .padding(.bottom, OverviewLayout.contentBottom)
            }
        }
    }

    /// The rings card: one ring per window beside a legend of every window. A provider
    /// with no window at all (nothing polled yet) keeps the burn-rate card rather than an
    /// empty one.
    @ViewBuilder
    private var heroCard: some View {
        if let service, !OverviewRingsRules.windows(for: service).isEmpty {
            OverviewRingsCard(
                service: service,
                mode: settings.percentMode,
                footer: OverviewCopy.footer(
                    verdict: verdict(for: service),
                    burn: dashboard.sessionBurn,
                    retained: service.isRetained
                ),
                retainedCaption: RetainedCopy.caption(for: service)
            )
        } else {
            burnCard
        }
    }

    /// Last-known numbers can't be extrapolated: a provider that stopped reporting isn't
    /// burning anything, whatever the last slope said.
    private func verdict(for service: ServiceSnapshot) -> BurnVerdict? {
        service.isRetained ? nil : BurnVerdict.make(
            burn: dashboard.sessionBurn,
            sessionBuckets: service.buckets.filter { $0.kind == .session }
        )
    }

    /// Titled after the window it actually predicts — with several providers a
    /// fixed "5-hour" was wrong for anyone whose leading window isn't five hours.
    private var burnCard: some View {
        let bucket = dashboard.burnBucket
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.burnTitle(bucket))
                    .font(OMFont.body)
                    .foregroundStyle(.secondary)
                Text(Self.burnValue(dashboard.sessionBurn, retained: service?.isRetained ?? false))
                    .font(OMFont.bodyStrong)
            }
            Spacer()
            // No ranked window: an empty ring, not a full one. `?? 0` here would draw
            // a complete circle the moment the app is counting down.
            OMRing(used: bucket?.clampedPercent, mode: settings.percentMode, size: .medium)
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .dashboardCard(padding: 14)
    }

    // MARK: - Burn-rate wording (pure, unit-tested)

    /// Names the window the prediction is for; a provider with no ranked window
    /// still gets an honest heading.
    nonisolated static func burnTitle(_ bucket: UsageBucket?) -> String {
        bucket.map { "\($0.label) burn rate" } ?? "Burn rate"
    }

    /// `retained`: the provider stopped reporting, so its numbers are frozen — a
    /// prediction drawn from them would describe a limit nobody is walking towards.
    nonisolated static func burnValue(_ burn: BurnRatePrediction?, retained: Bool = false) -> String {
        if retained { return "Paused" }
        guard let burn else { return "Not enough data" }
        guard let secs = burn.secondsToLimit else {
            return burn.percentPerMinute > 0 ? "Stable" : "Idle"
        }
        return "Hit limit in \(formatDuration(secs))"
    }

    /// The two lines of `burnCard` as one caption, for under the hero.
    nonisolated static func burnLine(
        burn: BurnRatePrediction?,
        bucket: UsageBucket?,
        retained: Bool = false
    ) -> String {
        "\(burnTitle(bucket)) · \(burnValue(burn, retained: retained))"
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
            Text("\(TokenFormat.formatTokens(tokens)) tokens")
                .font(OMFont.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .dashboardCard(padding: 14)
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
            if let caption = CostCopy.apiEquivalentCaption(
                isPayAsYouGo: service.map(CostCopy.isPayAsYouGo) ?? false
            ) {
                Text(caption)
                    .font(OMFont.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    nonisolated static func formatDuration(_ secs: TimeInterval) -> String {
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
}
