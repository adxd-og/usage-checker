import SwiftUI

/// Dashboard → Limits (spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, § Accounts without percent windows; `Dashboard-Limits(-Light).dc.html`):
/// what filled the selected provider's limit, and what a percent of it costs. The page is
/// `LimitsRules.page`'s, every word `LimitsCopy`'s and every measure `LimitsLayout`'s. The
/// share is `DashboardState.limitShare`, which `refreshLimitShare(kind:)` loads once the
/// provider's cost log is in, again after every ingest, and at once when the query on
/// screen changes (a reset, a mode change, a new budget).
struct LimitsView: View {
    /// The live snapshot: it decides the mode, the window and the switch's offer.
    @ObservedObject var appState: AppState
    @ObservedObject var dashboard: DashboardState
    /// The weekly budget pay as you go measures against.
    @ObservedObject private var settings = SettingsStore.shared

    @AppStorage(LimitsRules.windowKey) private var storedWindow: String = BucketKind.weekly.rawValue
    /// Opens the Settings window; `openBudgetSettings()` parks its tab first.
    @Environment(\.openSettings) private var openSettings

    /// The selected provider as the last poll saw it.
    private var service: ServiceSnapshot? {
        appState.snapshot.services.first { $0.id == dashboard.selectedService }
    }

    private var offeredKinds: [BucketKind] {
        LimitsRules.switchKinds(serviceID: dashboard.selectedService, service: service)
    }

    private var kind: BucketKind {
        LimitsRules.selectedKind(stored: storedWindow, offered: offeredKinds)
    }

    var body: some View {
        let now = Date()
        let key = LimitsLoadKey(
            query: LimitsRules.query(
                serviceID: dashboard.selectedService, service: service, kind: kind,
                weeklyBudgetUSD: settings.claudeWeeklyBudgetUSD, now: now, calendar: .current
            ),
            ingestedAt: dashboard.cliBreakdown?.updatedAt
        )
        // Measured once, off the width the tab is given, as History does: every row of the
        // list draws to one decision.
        return GeometryReader { proxy in
            scrollBody(isWide: LimitsLayout.isWideRows(detailWidth: proxy.size.width), now: now)
        }
        .task(id: key) {
            await load(key)
        }
    }

    /// Loads the share once this provider's cost log is in (`LimitsRules.loads`). Whether
    /// what arrives is current is the page's to say: `DashboardState` publishes the query
    /// each load answered.
    private func load(_ key: LimitsLoadKey) async {
        guard LimitsRules.loads(key) else { return }
        await dashboard.refreshLimitShare(kind: key.query.kind)
    }

    private func scrollBody(isWide: Bool, now: Date) -> some View {
        let kind = self.kind
        let page = LimitsRules.page(
            serviceID: dashboard.selectedService,
            kind: kind,
            service: service,
            weeklyBudgetUSD: settings.claudeWeeklyBudgetUSD,
            load: dashboard.limitShare,
            answered: dashboard.limitShareAnswer,
            now: now,
            calendar: .current
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardHeader(
                    title: LimitsCopy.title,
                    subtitle: LimitsCopy.subtitle,
                    showsServicePicker: false
                )
                controls(kind: kind)
                    .padding(.top, LimitsLayout.controlsTopPadding)
                    .padding(.leading, DashboardShellLayout.columnLeading)
                    .padding(.trailing, DashboardShellLayout.columnTrailing)
                content(page, isWide: isWide)
                    .padding(.top, LimitsLayout.sectionSpacing)
                    .padding(.leading, DashboardShellLayout.columnLeading)
                    .padding(.trailing, DashboardShellLayout.columnTrailing)
                    .padding(.bottom, LimitsLayout.columnBottom)
            }
        }
    }

    /// Settings on its Advanced tab, where the weekly budget is
    /// (`LimitsRules.budgetSettingsTab`).
    private func openBudgetSettings() {
        SettingsRoute.shared.pendingTab = LimitsRules.budgetSettingsTab.rawValue
        NSApp.activate()
        openSettings()
    }

    // MARK: - Controls

    /// The provider on the left, the window switch on the right, as History's controls
    /// row. They stack before they clip: the page never forces the window wider.
    private func controls(kind: BucketKind) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LimitsLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                Spacer(minLength: LimitsLayout.controlSpacing)
                windowSwitch(kind: kind)
            }
            VStack(alignment: .leading, spacing: LimitsLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                windowSwitch(kind: kind)
            }
        }
    }

    /// Session / Week, only the windows the account has (Codex Prolite: Week alone; Codex
    /// Free: Month); none in the spend modes.
    @ViewBuilder
    private func windowSwitch(kind: BucketKind) -> some View {
        let kinds = offeredKinds
        if !kinds.isEmpty {
            OMSegmentedControl(
                items: kinds.map {
                    OMSegmentItem(id: $0.rawValue, title: LimitsCopy.windowName(LimitsRules.span(of: $0, in: service)))
                },
                selection: Binding(
                    get: { kind.rawValue },
                    set: { storedWindow = $0 }
                ),
                alwaysShowsTitles: true,
                keyboardShortcuts: false,
                accessibilityLabel: LimitsCopy.windowPickerLabel
            )
            .fixedSize()
        }
    }

    // MARK: - Page

    /// The cards once the share is current; otherwise the sentence that says why not.
    @ViewBuilder
    private func content(_ page: LimitsPage, isWide: Bool) -> some View {
        switch page {
        case .ready(let load):
            cards(load, isWide: isWide)
        default:
            if let message = LimitsCopy.message(
                for: page, providerName: dashboard.displayName(for: dashboard.selectedService)
            ) {
                VStack(alignment: .leading, spacing: LimitsLayout.messageSpacing) {
                    Text(message)
                        .font(.system(size: LimitsLayout.messageSize))
                        .foregroundStyle(.om(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    // Claude pay as you go with nothing spent: the budget is what to set.
                    if let link = LimitsCopy.messageLink(for: page, serviceID: dashboard.selectedService) {
                        Button(link, action: openBudgetSettings)
                            .buttonStyle(.omLink)
                    }
                }
                .dashboardCard(padding: LimitsLayout.messagePadding)
            }
        }
    }

    /// The mode's cards, top to bottom as the mockup stacks them.
    private func cards(_ load: DashboardState.LimitShareLoad, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: LimitsLayout.sectionSpacing) {
            LimitsTopCard(text: LimitsCopy.topCard(for: load, now: Date()), onLink: openBudgetSettings)
            let windowSpan = LimitsRules.span(of: load.kind, in: service)
            LimitsRankedCard(
                load: load,
                title: LimitsCopy.rankedTitle(mode: load.request.mode, span: windowSpan),
                trailing: LimitsCopy.rankedTrailing(mode: load.request.mode, percent: load.share.percent),
                emptyText: LimitsCopy.noChats(mode: load.request.mode, span: windowSpan),
                isWide: isWide
            )
            // A new provider, window or measure starts the list capped again.
            .id(load.query)
        }
    }
}
