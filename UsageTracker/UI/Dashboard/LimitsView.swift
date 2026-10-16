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
    /// The Chats / Projects choice of every provider in one string ("claude=projects").
    @AppStorage(LimitsRules.groupingKey) private var storedGrouping: String = ""
    /// Opens the Settings window; `openBudgetSettings()` parks its tab first.
    @Environment(\.openSettings) private var openSettings
    /// The period picked: the current one until another is, and again after a provider or
    /// window change. `period` checks it is still on offer.
    @State private var chosenPeriod: LimitsPeriod = .current

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

    /// The account's mode, as the page measures it.
    private var mode: LimitMode? {
        service.flatMap { LimitShareRules.mode(of: $0, weeklyBudgetUSD: settings.claudeWeeklyBudgetUSD) }
    }

    /// What the period picker offers: the current period, then the finished windows the
    /// last load found or the earlier weeks.
    private var offeredPeriods: [LimitsPeriod] {
        LimitsRules.periods(
            mode: mode,
            pastWindows: LimitsRules.pastWindows(
                dashboard.limitPastWindows, serviceID: dashboard.selectedService, kind: kind
            )
        )
    }

    /// The period on screen.
    private var period: LimitsPeriod {
        LimitsRules.selectedPeriod(chosenPeriod, offered: offeredPeriods)
    }

    var body: some View {
        let now = Date()
        let key = LimitsLoadKey(
            query: LimitsRules.query(
                serviceID: dashboard.selectedService, service: service, kind: kind, period: period,
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
        // Another provider's or window's past periods are not this one's: start again on
        // the current period.
        .onChange(of: dashboard.selectedService) { chosenPeriod = .current }
        .onChange(of: storedWindow) { chosenPeriod = .current }
    }

    /// Loads the share once this provider's cost log is in (`LimitsRules.loads`). Whether
    /// what arrives is current is the page's to say: `DashboardState` publishes the query
    /// each load answered.
    private func load(_ key: LimitsLoadKey) async {
        guard LimitsRules.loads(key) else { return }
        await dashboard.refreshLimitShare(kind: key.query.kind, period: key.query.period)
    }

    private func scrollBody(isWide: Bool, now: Date) -> some View {
        let kind = self.kind
        let page = LimitsRules.page(
            serviceID: dashboard.selectedService,
            kind: kind,
            period: period,
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

    /// The list's grouping for `serviceID`, written back without touching another
    /// provider's (`LimitsRules.storing`).
    private func grouping(for serviceID: String) -> Binding<LimitsGrouping> {
        Binding(
            get: { LimitsRules.grouping(for: serviceID, stored: storedGrouping) },
            set: { storedGrouping = LimitsRules.storing($0, for: serviceID, in: storedGrouping) }
        )
    }

    // MARK: - Controls

    /// The provider on the left; the window switch and the period picker on the right, as
    /// the mockup sets them. They stack before they clip: the page never forces the window
    /// wider.
    private func controls(kind: BucketKind) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LimitsLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                Spacer(minLength: LimitsLayout.controlSpacing)
                windowSwitch(kind: kind)
                periodPicker(kind: kind)
            }
            VStack(alignment: .leading, spacing: LimitsLayout.controlSpacing) {
                ServicePicker(dashboard: dashboard)
                HStack(spacing: LimitsLayout.controlSpacing) {
                    windowSwitch(kind: kind)
                    periodPicker(kind: kind)
                }
            }
        }
    }

    /// The current period and the past ones (spec § The tab, item 1), named for the
    /// window's length; none while the current period is the only one.
    @ViewBuilder
    private func periodPicker(kind: BucketKind) -> some View {
        let periods = offeredPeriods
        if LimitsRules.canPickPeriod(periods), let mode {
            let span = LimitsRules.span(of: kind, in: service)
            let now = Date()
            LimitsPeriodPicker(
                entries: periods.map {
                    LimitsPeriodEntry(period: $0, name: LimitsCopy.periodName($0, mode: mode, span: span, now: now))
                },
                selection: Binding(get: { period }, set: { chosenPeriod = $0 })
            )
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
                for: page, providerName: dashboard.displayName(for: dashboard.selectedService), period: period
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

    /// The mode's cards, top to bottom as the mockup stacks them, worded for the period the
    /// load answered (spec § The tab, items 1–3).
    private func cards(_ load: DashboardState.LimitShareLoad, isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: LimitsLayout.sectionSpacing) {
            let windowSpan = LimitsRules.span(of: load.kind, in: service)
            let listGrouping = grouping(for: load.serviceID)
            LimitsTopCard(
                text: LimitsCopy.topCard(for: load, now: Date(), span: windowSpan),
                onLink: openBudgetSettings
            )
            LimitsRankedCard(
                load: load,
                title: LimitsCopy.rankedTitle(mode: load.request.mode, span: windowSpan, period: load.period),
                trailing: LimitsCopy.rankedTrailing(
                    mode: load.request.mode, percent: load.share.percent, period: load.period
                ),
                tail: LimitsRules.tailRows(of: load.share, mode: load.request.mode, serviceID: load.serviceID),
                emptyText: LimitsCopy.noChats(mode: load.request.mode, span: windowSpan, period: load.period),
                footnote: LimitsCopy.rowsFootnote(mode: load.request.mode),
                isWide: isWide,
                grouping: listGrouping
            )
            // A new provider, window, period or measure starts the list capped again.
            .id(load.query)
        }
    }
}
