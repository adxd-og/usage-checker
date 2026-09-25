import SwiftUI

/// Dashboard → Overview (liquid-glass spec § Screens, "Overview";
/// `Dashboard-Overview(-Light).dc.html`): the provider's windows as concentric rings beside
/// their legend, today's CLI dollars with the last 7 and 30 days, and today's tokens. Each
/// summary links to History, which owns the detail (Principle 4).
struct OverviewView: View {
    @ObservedObject var appState: AppState
    /// Observed, so the switch repaints an open dashboard rather than waiting for
    /// the next poll.
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var dashboard: DashboardState
    /// The window's tab. Following a link is a write here; the window follows.
    @AppStorage(DashboardTab.storageKey) private var storedTab: String = DashboardTab.overview.rawValue
    /// History's chart mode, which "Tokens by day" sets before it switches the tab.
    @AppStorage(OverviewLink.historyChartModeKey) private var historyChartMode: String = HistoryChartMode.cost.rawValue

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
                            OverviewCLICard(
                                title: OverviewCopy.cliTitle(shortName: dashboard.costSource.shortName),
                                cli: dashboard.cliBreakdown,
                                isLoading: dashboard.isLoadingCLI,
                                caption: CostCopy.apiEquivalentCaption(for: service),
                                onHistory: { follow(.history) }
                            )
                        }
                    }

                    // Under the cards: the same log's data, one question further ("what did
                    // those tokens do?").
                    if OverviewLayout.showsTokensCard(
                        hasBreakdown: dashboard.costSource.hasBreakdown,
                        todayTokens: dashboard.cliBreakdown?.todayTokenBreakdown.total ?? 0
                    ), let cli = dashboard.cliBreakdown {
                        TokensTodayCard(
                            breakdown: cli.todayTokenBreakdown,
                            onTokensByDay: { follow(.tokensByDay) },
                            costCaption: CostCopy.apiEquivalentCaption(for: service)
                        )
                    }
                }
                .padding(.top, OverviewLayout.contentTop)
                .padding(.leading, DashboardShellLayout.columnLeading)
                .padding(.trailing, DashboardShellLayout.columnTrailing)
                .padding(.bottom, OverviewLayout.contentBottom)
            }
        }
    }

    /// Follows a summary's link: History's chart mode first, then the tab, so History
    /// opens on the right chart rather than switching under the user.
    private func follow(_ link: OverviewLink) {
        if let mode = link.chartMode { historyChartMode = mode.rawValue }
        storedTab = link.tab.rawValue
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
                retainedCaption: RetainedCopy.caption(for: service),
                link: OverviewLink.onFirstCard(hasBreakdown: dashboard.costSource.hasBreakdown),
                onLink: { follow($0) }
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
                // Standing in for the rings of a provider with no current window: History
                // still has its readings, and there is no CLI card to carry the link.
                if let link = OverviewLink.onFirstCard(hasBreakdown: dashboard.costSource.hasBreakdown) {
                    Button(link.title) { follow(link) }
                        .buttonStyle(.omLink)
                }
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
