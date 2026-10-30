import SwiftUI

/// What the island's body shows when there are no tiles to draw (spec 2026-10-25
/// § Package 1, Nothing on). Top level, not nested in the view, so the rule's answer is a
/// plain value a test compares.
enum PopoverEmptyBody: Equatable, Sendable {
    /// Every provider is off: says so and opens Settings › Providers.
    case nothingOn
    /// The first poll has not landed.
    case loading
}

/// The island's content (notch-island spec 2026-10-29 § 3.3, § 3.4), in the island and in the
/// panel alike: the strip beside the camera ("Omelette"; how long ago, and the spinner — in a
/// provider's page "‹ All" and the providers' logos), then the habitat's column and one
/// two-column grid — the provider tiles or a provider's page, the agents card beside the cost
/// tile over keep awake, the footer. The rules decide (`ProviderGridRules`,
/// `KeepAwakeCardLayout`, `IslandHeightRules`, `IslandNavigation`); this view lays out and
/// measures. A tile opens its provider's page (`IslandNavigationModel`).
struct PopoverView: View {
    @ObservedObject var state: AppState
    /// The layout for the display the island opens on and the agents list's cap
    /// (`IslandLayoutModel`), owned by `IslandController` for the app's life. It re-renders
    /// this view only when one of them moves.
    @ObservedObject var layout: IslandLayoutModel
    /// Where the content is, All or a provider's page, and the move toward it
    /// (`IslandNavigationModel`, § 3.4), owned by `IslandController` for the app's life.
    @ObservedObject var navigation: IslandNavigationModel
    /// The display mode. Observed here rather than read once, so flipping the switch
    /// in Settings repaints the island under the cursor.
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var dashboard = DashboardState.shared
    @ObservedObject private var agents = AgentSessionStore.shared

    /// Whether each source's hooks are installed decides one line of copy, so it
    /// is read once per open off the main thread instead of on every layout pass.
    @State private var claudeHooksInstalled = false
    @State private var codexHooksInstalled = false
    /// The one-time offer to install Claude's hooks, decided from the same read.
    @State private var hooksPromptVisible = false
    /// Whether Antigravity is installed, for its page's state help (`ProviderStateHelp`):
    /// read with the hooks, once per open, off the main thread.
    @State private var antigravityInstalled = false

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    // MARK: - Metrics (§ 3.3 tokens)

    nonisolated static let padding: CGFloat = ProviderGridRules.padding
    /// The panel's body: chrome glass in the 24 pt corner. The island is the black shape
    /// `IslandRootView` draws behind the content (§ 3.1, Appearance: glass only on chrome).
    nonisolated static let bodyCorner: OMCornerContext = .popover
    nonisolated static let bodyGlass: OMGlassKind = .chrome
    /// "Omelette" in the strip.
    nonisolated static let stripTitleSize: CGFloat = 13
    nonisolated static let metaSize: CGFloat = 11.5
    /// Between the camera and the strip's words on either side of it.
    nonisolated static let stripNotchGap: CGFloat = 10
    nonisolated static var staleNoticeToken: OMColorToken { .warning }

    var body: some View {
        let placed = layout.layout
        let columns = placed.columns
        VStack(alignment: .leading, spacing: ProviderGridRules.gap) {
            if placed.kind == .panel {
                stripRow(notchWidth: 0)
                    .frame(height: IslandHeightRules.panelHeaderHeight)
            }
            HStack(alignment: .top, spacing: ProviderGridRules.habitatGap) {
                if placed.showsHabitat {
                    habitatSlot
                }
                rightViewport(columns)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, placed.kind == .island ? IslandHeightRules.islandTopInset : Self.padding)
        .padding(.bottom, placed.kind == .island ? 0 : Self.padding)
        .frame(width: placed.bodyWidth, alignment: .topLeading)
        // The strip beside the camera, above the content's own frame: the band
        // `IslandGeometry` keeps for the notch, inside the island's shape (plan ruling R5).
        .overlay(alignment: .top) {
            if placed.kind == .island {
                stripRow(notchWidth: placed.notchWidth)
                    .padding(.horizontal, Self.padding)
                    .frame(width: placed.bodyWidth, height: placed.stripHeight)
                    .offset(y: -placed.stripHeight)
            }
        }
        .modifier(PanelBody(isPanel: placed.kind == .panel))
        // Same as the dashboard: a percentage or a reset time can be selected and
        // copied straight out of the island.
        .textSelection(.enabled)
        .task { await refreshHookStatus() }
        // A page whose provider left falls back to All; with one provider left, its page is
        // home (§ 3.4).
        .onChange(of: providerIDs, initial: true) { _, ids in
            navigation.request(.providersChanged, providers: ids)
        }
    }

    private func refreshHookStatus() async {
        let helperPath = AgentPaths.helperSymlinkURL.path
        let claudeSettings = AgentPaths.claudeSettingsURL
        let codexConfig = AgentPaths.codexConfigURL
        // Claude's raw status travels back too: the prompt row and the "Enable
        // precise status" link are two answers to the same file read, and reading
        // it twice could disagree with itself.
        let read = await Task.detached(priority: .utility) { () -> (claude: HookInstallStatus, claudeSatisfied: Bool, codexSatisfied: Bool, claudePresent: Bool, antigravityInstalled: Bool) in
            // "Satisfied" = nothing the island's link could improve: installed,
            // owned by another tool (conflict), or no config file at all because
            // that CLI isn't on this machine. Only "not installed" / "outdated"
            // earn the "Enable precise status" link.
            func satisfied(_ status: HookInstallStatus, _ configURL: URL) -> Bool {
                switch status {
                case .installed, .conflict: return true
                case .outdated: return false
                case .notInstalled: return !FileManager.default.fileExists(atPath: configURL.path)
                }
            }
            let claude = AgentHooksInstaller.claudeStatus(settingsURL: claudeSettings, helperPath: helperPath)
            return (
                claude,
                satisfied(claude, claudeSettings),
                satisfied(AgentHooksInstaller.codexStatus(configURL: codexConfig, helperPath: helperPath), codexConfig),
                AgentHooksPrompt.claudeIsPresent(),
                // Antigravity's state help offers the app when it is installed.
                FileManager.default.fileExists(atPath: ProviderStateHelp.antigravityAppPath)
            )
        }.value
        claudeHooksInstalled = read.claudeSatisfied
        codexHooksInstalled = read.codexSatisfied
        antigravityInstalled = read.antigravityInstalled
        hooksPromptVisible = AgentHooksPrompt.shouldShow(
            claudePresent: read.claudePresent,
            status: read.claude,
            dismissed: SettingsStore.shared.agentsHooksPromptDismissed
        )
    }

    /// The prompt's Enable button. On success the row goes away and precise
    /// status starts with the next hook event; on failure the offer stands and
    /// Settings → Agents spells out what stopped it.
    private func enableClaudeHooks() {
        do {
            try AgentHooksPrompt.installClaudeHooks()
            Task { await refreshHookStatus() }
        } catch {
            SettingsStore.shared.agentsHooksPromptDismissed = false
            openAgentsSettings()
        }
    }

    private func dismissHooksPrompt() {
        SettingsStore.shared.agentsHooksPromptDismissed = true
        withAnimation(.smooth(duration: 0.2)) { hooksPromptVisible = false }
    }

    private func openAgentsSettings() {
        SettingsRoute.shared.pendingTab = SettingsRoute.agentsTab
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    /// Settings on its Providers tab, where the switches are (the nothing-on link).
    private func openProvidersSettings() {
        SettingsRoute.shared.pendingTab = SettingsTab.providers.rawValue
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - The page

    private var displayedServices: [ServiceSnapshot] { state.snapshot.services }

    /// The providers on screen by id, in display order: what navigation counts (§ 3.4); a
    /// provider switched off is not among them.
    private var providerIDs: [String] { displayedServices.map(\.id) }

    /// The provider whose page is shown; nil on All. During a move, the page more than half in
    /// (`IslandDrillLook.shownPage`): the strip, the meta line and the lower row follow it.
    private var selectedService: ServiceSnapshot? {
        service(on: IslandDrillLook.shownPage(navigation.frame))
    }

    /// The service a page is about; nil for All, and for a provider no longer on screen.
    private func service(on page: IslandNavigation.Page) -> ServiceSnapshot? {
        guard case .provider(let id) = page else { return nil }
        return displayedServices.first { $0.id == id }
    }

    // MARK: - Provider tab rules (pure, unit-tested)

    /// `Popover-Claude.dc.html`'s weekly-limits card: 14 pt in, 14 pt between rows.
    nonisolated static let groupPadding: CGFloat = 14
    nonisolated static let groupSpacing: CGFloat = 14

    /// A window nobody has touched keeps its row, so the list stays in order, but
    /// dims — as its ring did.
    nonisolated static func limitRowOpacity(_ bucket: UsageBucket) -> Double {
        bucket.clampedPercent == 0 ? 0.55 : 1
    }

    /// Whether a weekly-limits row folds behind "N unused windows": only a model-specific
    /// window nobody has touched (under 0.05%). A `.weekly` window is a limit the whole
    /// plan shares and keeps its row at 0% too: Claude's "All models", and each
    /// Antigravity pool's weekly alike.
    nonisolated static func foldsWhenUnused(_ bucket: UsageBucket) -> Bool {
        bucket.kind == .modelSpecific && bucket.clampedPercent < 0.05
    }

    /// Whether a provider tab draws its spend card: the week's dollars (as the headline
    /// of a windowless account, or under a hero), an enabled extra-usage or spend
    /// limit, or a prepaid credit pool.
    nonisolated static func showsSpendGroup(service: ServiceSnapshot, hasHero: Bool) -> Bool {
        if !hasHero, service.spendHeadline != nil { return true }
        if let extra = service.extraUsage, extra.isEnabled { return true }
        if !creditPools(service).isEmpty { return true }
        return hasHero && (service.weekCost ?? 0) > 0
    }

    /// The prepaid credit pools a provider tab lists in its spend card, in the
    /// provider's order. A pool at 0 % keeps its row: it is money the account has.
    nonisolated static func creditPools(_ service: ServiceSnapshot) -> [UsageBucket] {
        service.creditPools
    }

    /// A credit row's value: `"$231 / $250"`, used over limit in whole dollars, the
    /// extra-usage row's currency style. nil for a bucket that is not a credit pool.
    nonisolated static func creditRowValue(_ bucket: UsageBucket, locale: Locale = .current) -> String? {
        guard let credit = bucket.credit else { return nil }
        return CreditCopy.value(usedDollars: credit.usedDollars, limitDollars: credit.limitDollars, locale: locale)
    }

    /// A credit row's tooltip: `"Expires 5 Nov, 7:59"`. A pool's reset is when its
    /// unspent credit lapses, not when a window starts over. nil when the provider gave
    /// no date.
    nonisolated static func creditRowHelp(
        _ bucket: UsageBucket,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        ResetCopy.absolute(resetsAt: bucket.resetsAt, now: now, calendar: calendar, locale: locale)
            .map { "Expires \($0)" }
    }

    /// Whether a live provider tab says "Server responded but returned no usage data":
    /// nothing at all to draw. A credit pool is a bucket, so an account whose only
    /// reading is its credit has something to show.
    nonisolated static func nothingToShow(_ service: ServiceSnapshot) -> Bool {
        service.buckets.isEmpty && service.extraUsage == nil && (service.weekCost ?? 0) == 0
    }

    /// A provider tab's state line: its word in its colour ("Not running" in secondary,
    /// "Sign in" amber, "Error" red); nil while the provider is live.
    nonisolated static func stateLabel(for service: ServiceSnapshot) -> OMColoredText? {
        guard service.state != .ok else { return nil }
        return OMColoredText(text: RetainedCopy.chipText(for: service.state),
                             token: OMProviderTile.stateToken(for: service.state))
    }

    /// The body with no tiles to draw; nil while there is anything to draw. Nothing on wins
    /// even over services the poll that switched the last provider off has not dropped yet.
    nonisolated static func emptyBody(pollsNothing: Bool, services: [ServiceSnapshot]) -> PopoverEmptyBody? {
        if pollsNothing { return .nothingOn }
        return services.isEmpty ? .loading : nil
    }

    // MARK: - The strip

    /// Beside the camera (§ 3.3, § 3.4): at All and at the only provider's page "Omelette" on
    /// the left and, on the right, how long ago the numbers came (and the spinner while a
    /// refresh runs); in a page with siblings "‹ All" on the left and the providers' logos on
    /// the right (plan ruling R9). During a move the two sets cross-fade late
    /// (`IslandDrillLook.navigationOpacity`); only the set of the page shown takes clicks and
    /// VoiceOver. In the panel the same row, with no camera between.
    private func stripRow(notchWidth: CGFloat) -> some View {
        let shown = IslandNavigation.isDrilledIn(IslandDrillLook.shownPage(navigation.frame), providers: providerIDs)
        let fade = IslandDrillLook.navigationOpacity(navigation.frame, providers: providerIDs)
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                stripTitle
                    .opacity(1 - fade)
                    .accessibilityHidden(shown)
                backButton
                    .opacity(fade)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if notchWidth > 0 {
                Color.clear
                    .frame(width: notchWidth + 2 * Self.stripNotchGap)
            }
            ZStack(alignment: .trailing) {
                metaLine(service: selectedService)
                    .opacity(1 - fade)
                    .accessibilityHidden(shown)
                logos
                    .opacity(fade)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var stripTitle: some View {
        Text(PopoverCopy.appName)
            .font(.system(size: Self.stripTitleSize, weight: .semibold))
            .foregroundStyle(.om(.text))
            .lineLimit(1)
    }

    /// "‹ All": back to All (§ 3.4), as Esc, ⌘0 and a swipe right are.
    private var backButton: some View {
        Button {
            navigation.request(.back, providers: providerIDs)
        } label: {
            Label(IslandNavigationCopy.backTitle, systemImage: "chevron.left")
        }
        .buttonStyle(.omCapsule(.small))
        .help(IslandNavigationCopy.backHelp)
        .accessibilityLabel(IslandNavigationCopy.backAccessibilityLabel)
    }

    /// The providers' logos, the sibling switcher (§ 3.4): the page shown on the raised pill,
    /// the needs-you dot on a provider whose session waits; a click opens that page.
    private var logos: some View {
        HStack(spacing: IslandLogoButton.spacing) {
            ForEach(Array(displayedServices.enumerated()), id: \.element.id) { index, service in
                IslandLogoButton(
                    service: service,
                    selected: IslandDrillLook.shownPage(navigation.frame) == .provider(service.id),
                    waiting: ProviderGridRules.showsWaitingDot(serviceID: service.id, sessions: agents.sessions),
                    position: index + 1
                ) {
                    navigation.request(.logo(service.id), providers: providerIDs)
                }
            }
        }
    }

    /// How long ago the numbers came, after a provider's name and plan when it has one
    /// (`PopoverCopy.metaLine`), and the spinner while a refresh runs: in the strip at All and
    /// at the only provider's page, as a page's first row otherwise. Only the relative time
    /// needs a clock tick.
    private func metaLine(service: ServiceSnapshot?) -> some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(PopoverCopy.metaLine(service: service, fetchedAt: state.snapshot.fetchedAt, now: context.date))
            }
            .font(.system(size: Self.metaSize))
            .foregroundStyle(.om(.secondary))
            .lineLimit(1)
            .truncationMode(.tail)
            if state.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The habitat

    /// The habitat's column (§ 3.3): the pet lives here from P5c on. Until then empty space
    /// keeps its 150 pt, so the grid has its final width (plan ruling R4). No fill and no
    /// edge: the pet stands on the island itself (owner 2026-10-30).
    private var habitatSlot: some View {
        Color.clear
            .frame(width: ProviderGridRules.habitatWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    // MARK: - The right column

    /// Everything right of the habitat, one grid: the stale notice, the tiles or a provider's
    /// page, the lower row, the footer. It reports its own height; a part of the lower row that
    /// is not there takes its measurement with it.
    private func rightColumn(_ columns: ProviderGridRules.Columns) -> some View {
        VStack(alignment: .leading, spacing: ProviderGridRules.gap) {
            if state.snapshot.isStale && state.snapshot.hasAnyData { staleNotice }
            upper(columns)
            lowerRow(columns)
            footer
        }
        .frame(width: columns.right, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            layout.record(rightColumn: height)
        }
        .onChange(of: lowerRowAgents == nil, initial: true) { _, absent in
            if absent {
                layout.record(agentsColumn: nil)
                layout.record(list: nil)
            }
        }
        .onChange(of: showsCostInLowerRow, initial: true) { _, shown in
            if !shown { layout.record(costTile: nil) }
        }
    }

    /// The right column on screen, inside one scroll view that is always there (plan ruling
    /// R8). While the column fits, the frame is the column's own height rounded up, so there
    /// is nothing to scroll and `.basedOnSize` keeps it from bouncing; when even the agents
    /// list's first two rows cannot fit the budget, the frame is the budget and it scrolls
    /// (§ 3.3: no clipping). Never `scrollDisabled`: that is an environment value and would
    /// also stop the agents list past its cap and an expanded agent detail inside it (review
    /// finding 1). One structure either way, so no card is rebuilt when scrolling starts or
    /// stops.
    private func rightViewport(_ columns: ProviderGridRules.Columns) -> some View {
        ScrollView(.vertical) {
            rightColumn(columns)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(width: columns.right, height: layout.rightColumnViewport ?? 0)
    }

    /// The tiles on All (with the hooks offer under them), a provider's page, or what
    /// shows while nothing can.
    @ViewBuilder
    private func upper(_ columns: ProviderGridRules.Columns) -> some View {
        switch Self.emptyBody(pollsNothing: state.pollsNothing, services: displayedServices) {
        case .nothingOn?:
            nothingOn
        case .loading?:
            loadingRow
        case nil:
            if let service = selectedService {
                pageLayer(service)
            } else {
                allLayer(columns)
            }
        }
    }

    /// All: the tiles, then the hooks offer under them. A point of room above the first row for
    /// a tile's hover lift: the right column's scroll view clips at its top edge (R11).
    private func allLayer(_ columns: ProviderGridRules.Columns) -> some View {
        VStack(alignment: .leading, spacing: ProviderGridRules.gap) {
            tileGrid(columns)
            if hooksPromptVisible {
                OMHooksPromptRow(onEnable: enableClaudeHooks, onDismiss: dismissHooksPrompt)
            }
        }
        .padding(.top, OMProviderTile.hoverLift)
    }

    /// A provider's page: its meta line when it has siblings (their logos hold the strip, R9),
    /// then its state, numbers, dollars and hooks offer.
    private func pageLayer(_ service: ServiceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            if IslandNavigation.isDrilledIn(.provider(service.id), providers: providerIDs) {
                metaLine(service: service)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // This page's own burn rate, not the dashboard's selection.
            ProviderDetail(
                service: service,
                mode: settings.percentMode,
                burn: dashboard.burn(for: service.id),
                // The offer is about Claude's settings.json, so it belongs on Claude's page
                // and nowhere else.
                showsHooksPrompt: hooksPromptVisible && AgentSource(rawValue: service.id) == .claude,
                onEnableHooks: enableClaudeHooks,
                onDismissHooksPrompt: dismissHooksPrompt,
                antigravityInstalled: antigravityInstalled
            )
        }
    }

    /// The tile rows (`ProviderGridRules.grid`): an odd count's orphan slot holds the cost
    /// tile.
    private var tiles: ProviderGridRules.Grid {
        ProviderGridRules.grid(
            serviceIDs: displayedServices.map(\.id),
            showsCostTile: ProviderGridRules.showsCostTile(displayedServices)
        )
    }

    /// The provider tiles two a row, each row as tall as its taller tile; every bar starts
    /// after one shared label column.
    private func tileGrid(_ columns: ProviderGridRules.Columns) -> some View {
        let labelWidth = ProviderGridRules.barLabelWidth(
            labelWidths: displayedServices
                .compactMap { OMProviderTile.barLabel(for: $0) }
                .map { TextMeasure.width($0, size: OMProviderTile.barLabelSize) },
            tileInterior: columns.half - 2 * OMProviderTile.padding
        )
        return VStack(spacing: ProviderGridRules.gap) {
            ForEach(Array(tiles.tileRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: ProviderGridRules.gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, slot in
                        tileSlot(slot, barLabelWidth: labelWidth)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func tileSlot(_ slot: ProviderGridRules.Slot, barLabelWidth: CGFloat) -> some View {
        switch slot {
        case .provider(let id):
            if let service = displayedServices.first(where: { $0.id == id }) {
                // A tile opens its provider's page (§ 3.4).
                OMProviderTile(
                    service: service,
                    mode: settings.percentMode,
                    barLabelWidth: barLabelWidth,
                    showsWaitingDot: ProviderGridRules.showsWaitingDot(serviceID: id, sessions: agents.sessions)
                ) {
                    navigation.request(.tile(id), providers: providerIDs)
                }
            }
        case .cost:
            OMCostTile(services: displayedServices, today: state.todayCosts, fillsHeight: true)
        case .empty:
            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
        }
    }

    /// What the lower row's agents card lists and whether its "Enable precise status" link
    /// shows.
    private struct LowerRowAgents {
        let sessions: [AgentSession]
        let grouped: Bool
        let hooksInstalled: Bool
    }

    /// All: every session, grouped by state. A provider's page: that provider's sessions,
    /// needs-you first; none for a provider without agents (plan ruling R2), nor while
    /// loading or with every provider off.
    private var lowerRowAgents: LowerRowAgents? {
        guard Self.emptyBody(pollsNothing: state.pollsNothing, services: displayedServices) == nil else { return nil }
        guard let service = selectedService else {
            // The link shows while either source is still guessing, never under the prompt
            // row that offers the same thing.
            return LowerRowAgents(
                sessions: agents.sessions,
                grouped: true,
                hooksInstalled: (claudeHooksInstalled && codexHooksInstalled) || hooksPromptVisible
            )
        }
        guard let source = AgentSource(rawValue: service.id) else { return nil }
        let showsPrompt = hooksPromptVisible && source == .claude
        return LowerRowAgents(
            sessions: agents.sessions(for: source),
            grouped: false,
            hooksInstalled: (source == .codex ? codexHooksInstalled : claudeHooksInstalled) || showsPrompt
        )
    }

    /// The cost tile over keep awake: on All, when an even provider count leaves no orphan
    /// slot for it.
    private var showsCostInLowerRow: Bool {
        Self.emptyBody(pollsNothing: state.pollsNothing, services: displayedServices) == nil
            && selectedService == nil
            && tiles.costInLowerRow
    }

    /// The grid's lower row (§ 3.3): the agents card | the cost tile over keep awake. Both
    /// halves are as tall as the taller; each part reports its own height before the row
    /// stretches it, so `IslandHeightRules` can size the agents list to the island. With no
    /// agents card the cost tile over keep awake spans the row (`ProviderGridRules.lowerRow`).
    private func lowerRow(_ columns: ProviderGridRules.Columns) -> some View {
        let agentsCard = lowerRowAgents
        let row = ProviderGridRules.lowerRow(columns: columns, hasAgentsCard: agentsCard != nil)
        return HStack(alignment: .top, spacing: ProviderGridRules.gap) {
            if let card = agentsCard {
                AgentsSection(
                    sessions: card.sessions,
                    grouped: card.grouped,
                    hooksInstalled: card.hooksInstalled,
                    embedded: true,
                    maxListHeight: layout.agentsListCap,
                    onListGeometry: { layout.record(list: $0) },
                    onEnable: openAgentsSettings
                )
                .padding(.vertical, ProviderGridRules.agentsCardVerticalPadding)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    layout.record(agentsColumn: height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .popoverSurface(.group)
            }
            VStack(spacing: ProviderGridRules.gap) {
                if showsCostInLowerRow {
                    OMCostTile(services: displayedServices, today: state.todayCosts)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            layout.record(costTile: height)
                        }
                }
                // Keep awake with the lid closed (spec 2026-10-26, § UI): at this place on
                // every view, so its typed fields survive a tab switch. Only its width moves
                // when the agents card comes or goes; the card is the row's optional first
                // child, never an if/else around this one.
                KeepAwakeSection(interiorWidth: row.keepAwakeInterior) { height in
                    layout.record(keepAwake: height)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: row.otherWidth)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Nothing to draw

    /// Every provider switched off: the fact, where to change it, and a link that opens
    /// Settings on Providers.
    private var nothingOn: some View {
        VStack(alignment: .leading, spacing: OMSpacing.xs) {
            Text(NothingOnCopy.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.om(.text))
            Text(NothingOnCopy.hint)
                .font(.system(size: 12.5))
                .foregroundStyle(.om(.secondary))
            Button(NothingOnCopy.button, action: openProvidersSettings)
                .buttonStyle(.omLink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, OMSpacing.xs)
    }

    private var loadingRow: some View {
        HStack {
            ProgressView().controlSize(.small)
            Text(PopoverCopy.loading)
                .font(.system(size: 12.5))
                .foregroundStyle(.om(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, OMSpacing.xs)
    }

    /// Last-good data stays on screen; this row says why it isn't moving.
    private var staleNotice: some View {
        noticeRow(
            icon: "wifi.exclamationmark", token: Self.staleNoticeToken,
            text: PopoverCopy.staleNotice(fetchedAt: state.snapshot.fetchedAt)
        )
        .help(PopoverCopy.staleNoticeHelp(lastError: state.snapshot.lastError))
    }

    private func noticeRow(icon: String, token: OMColorToken, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(.om(token))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.om(.secondary))
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    /// `Main.dc.html`'s footer: Dashboard, the floating window and Settings on glass,
    /// then Quit (`PopoverFooterRules.buttons`, `.trailing`). No version link: Settings
    /// → General carries the version and the GitHub link. Refresh has no button; ⌘R
    /// stays (`PopoverFooterRules.keyboardOnly`).
    private var footer: some View {
        footerRow
            .padding(.top, 2)
            .background { keyboardOnlyShortcuts }
    }

    private var footerRow: some View {
        HStack(spacing: PopoverFooterRules.spacing) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            } label: {
                Label(PopoverFooterRules.title(.dashboard), systemImage: PopoverFooterRules.symbol(.dashboard))
            }
            .buttonStyle(.omCapsule(.regular))
            .modifier(FooterShortcut(action: .dashboard))
            .help(PopoverFooterRules.help(.dashboard))

            Button {
                FloatingWindowController.shared.toggle()
            } label: {
                Label(
                    PopoverFooterRules.title(.floatingWindow),
                    systemImage: PopoverFooterRules.symbol(.floatingWindow, floatingWindowOpen: FloatingWindowController.shared.isOpen)
                )
            }
            .buttonStyle(.omCircle)
            .help(PopoverFooterRules.help(.floatingWindow, floatingWindowOpen: FloatingWindowController.shared.isOpen))

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label(PopoverFooterRules.title(.settings), systemImage: PopoverFooterRules.symbol(.settings))
            }
            .buttonStyle(.omCircle)
            .modifier(FooterShortcut(action: .settings))
            .help(PopoverFooterRules.help(.settings))

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text(PopoverFooterRules.title(.quit))
                    .font(.system(size: OMButtonRules.fontSize))
                    .foregroundStyle(.om(.secondary))
                    .padding(.horizontal, 10)
                    .frame(height: OMButtonRules.height(.regular))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(FooterShortcut(action: .quit))
            .help(PopoverFooterRules.help(.quit))
        }
    }

    /// Shortcuts with no button: invisible, zero-sized and hidden from VoiceOver, but
    /// in the view tree, so ⌘R still reaches them.
    private var keyboardOnlyShortcuts: some View {
        Button(PopoverFooterRules.title(.refresh)) { state.refreshNow() }
            .modifier(FooterShortcut(action: .refresh))
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The panel's body: the content's own chrome glass over the window background, in the
/// 24 pt corner. The island has none: it is the black shape behind the content.
private struct PanelBody: ViewModifier {
    let isPanel: Bool

    func body(content: Content) -> some View {
        if isPanel {
            content
                .omGlass(PopoverView.bodyGlass, in: OMCornerShape(PopoverView.bodyCorner))
                .background {
                    OMWindowBackground()
                        .clipShape(OMCornerShape(PopoverView.bodyCorner))
                }
        } else {
            content
        }
    }
}

/// ⌘ plus the rule's key for one footer action; nothing for an action without one.
private struct FooterShortcut: ViewModifier {
    let action: PopoverAction

    func body(content: Content) -> some View {
        if let key = PopoverFooterRules.shortcutKey(action) {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Provider tab

/// A provider's page in the right column (opened from its tile, its logo beside the camera or
/// its shortcut, § 3.4): its state, the hero ring, the weekly limits, the dollars and the
/// hooks offer, across the grid. Its agents are the lower row's card (P3a plan ruling R2).
private struct ProviderDetail: View {
    let service: ServiceSnapshot
    let mode: PercentDisplay.Mode
    let burn: BurnRatePrediction?
    var showsHooksPrompt: Bool = false
    var onEnableHooks: () -> Void = {}
    var onDismissHooksPrompt: () -> Void = {}
    /// Whether Antigravity is installed, for its state help (`ProviderStateHelp`).
    var antigravityInstalled: Bool = false

    @State private var showUnusedWindows = false

    private var sessionBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .session } }
    private var weeklyBuckets: [UsageBucket] { service.buckets.filter { $0.kind == .weekly || $0.kind == .modelSpecific } }
    /// The session window when the service has one: "can I keep working right
    /// now" is what this tab is for, and every other window still gets a row
    /// below. Only a service without a session falls back to the worst window.
    private var hero: UsageBucket? { WindowRanking.detailHero(for: service) }
    /// Any *additional* session window — usually none, now that the first one is
    /// the hero. A second session window would otherwise vanish from the tab.
    private var sessionRows: [UsageBucket] { WindowRanking.sessionRows(for: service, hero: hero) }
    /// The weekly-limit rows and the fold (`ProviderGridRules.weeklyRows`).
    private var weeklyRows: ProviderGridRules.WeeklyRows {
        ProviderGridRules.weeklyRows(for: service, hero: hero, showsUnused: showUnusedWindows)
    }
    private var nothingToShow: Bool { PopoverView.nothingToShow(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            if let stateLabel = PopoverView.stateLabel(for: service) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        // A retained provider's caption already carries the message;
                        // saying it twice, two lines apart, reads as a bug.
                        if !service.isRetained, let msg = service.stateMessage, !msg.isEmpty {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.om(.secondary))
                                .lineLimit(3)
                        }
                        Spacer()
                        ServiceStateLabel(service: service, label: stateLabel, antigravityInstalled: antigravityInstalled)
                    }
                    if let caption = RetainedCopy.caption(for: service) {
                        Text(caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.om(.secondary))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Last-good data is retained through a failure, so the numbers below stay
            // on screen whatever the state chip says — dimmed, because they're old.
            usageBlock
                .opacity(service.isRetained ? 0.55 : 1)
            if showsHooksPrompt {
                OMHooksPromptRow(onEnable: onEnableHooks, onDismiss: onDismissHooksPrompt)
            }
        }
    }

    /// Everything the provider itself reported, as one block so the dimming for
    /// last-known values is a single decision: the hero ring, the limits card
    /// (`Popover-Claude.dc.html`: weekly limits as bars) and the spend card.
    @ViewBuilder
    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: OMSpacing.m) {
            if let hero {
                // Last-known numbers can't be extrapolated: a provider that stopped
                // reporting isn't burning anything, whatever the last slope said.
                // The caption under the state already says the numbers are frozen —
                // same call the dashboard's hero makes (`OverviewView.heroCard`).
                OMHero(
                    hero: hero,
                    mode: mode,
                    verdict: service.isRetained
                        ? nil
                        : BurnVerdict.make(burn: burn, sessionBuckets: sessionBuckets)
                )
            }
            if !sessionRows.isEmpty || !weeklyRows.shown.isEmpty || weeklyRows.showsToggle {
                limitsGroup
            }
            if PopoverView.showsSpendGroup(service: service, hasHero: hero != nil) {
                spendGroup
            }
            if service.state == .ok, nothingToShow {
                Text("Server responded but returned no usage data.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.om(.secondary))
                    .lineLimit(2)
            }
        }
    }

    /// A second session window (rare), then the weekly limits as bars under their
    /// heading, in one card.
    private var limitsGroup: some View {
        VStack(alignment: .leading, spacing: PopoverView.groupSpacing) {
            ForEach(sessionRows) { bucket in
                OMKeyValueRow(
                    label: bucket.label,
                    value: WindowRanking.sessionRowValue(bucket, mode: mode),
                    barUsedPercent: bucket.clampedPercent,
                    barMode: mode,
                    pace: bucket.elapsedFraction(),
                    help: Self.resetTooltip(bucket)
                )
            }
            if !weeklyRows.shown.isEmpty {
                OMSectionHeader(title: "Weekly limits", trailing: weeklyReset)
                ForEach(weeklyRows.shown) { bucket in
                    // The ring's tooltip and spoken line carry over: "when exactly?"
                    // for the pointer, the full reset date for VoiceOver.
                    OMKeyValueRow(
                        label: PopoverCopy.limitRowLabel(bucket.label),
                        value: PercentDisplay.percentText(bucket.clampedPercent, mode: mode),
                        barUsedPercent: bucket.clampedPercent,
                        barMode: mode,
                        pace: bucket.elapsedFraction(),
                        help: OMRingRow.tooltip(for: bucket),
                        valueStyle: .figure,
                        accessibilityText: OMRingRow.accessibilityLabel(for: bucket, mode: mode)
                    )
                    .opacity(PopoverView.limitRowOpacity(bucket))
                }
            }
            unusedToggle
        }
        .padding(PopoverView.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface(.group)
    }

    /// The dollars: a windowless account's week as its headline, the extra-usage or
    /// spend limit, each prepaid credit pool, the week under a hero, and the
    /// API-equivalent line once.
    private var spendGroup: some View {
        VStack(alignment: .leading, spacing: PopoverView.groupSpacing) {
            if hero == nil, let cost = service.spendHeadline {
                // Pay-as-you-go without windows: the 7-day spend is the headline — live,
                // or last known and dimmed with the rest of this block.
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(cost), valueStyle: .figure)
            }
            if let extra = service.extraUsage, extra.isEnabled {
                OMKeyValueRow(
                    label: extraUsageTitle(plan: service.plan),
                    value: "\(OMCostTile.money(extra.usedCredits)) / \(extra.monthlyLimit.formatted(.currency(code: "USD").precision(.fractionLength(0))))",
                    barUsedPercent: extra.utilization,
                    barMode: mode
                )
            }
            // A prepaid credit pool is money the account has, not a limit: its dollars
            // sit next to extra usage and never among the weekly limits.
            ForEach(PopoverView.creditPools(service)) { pool in
                OMKeyValueRow(
                    label: pool.label,
                    value: PopoverView.creditRowValue(pool) ?? "",
                    barUsedPercent: pool.clampedPercent,
                    barMode: mode,
                    help: PopoverView.creditRowHelp(pool)
                )
            }
            if hero != nil, let week = service.weekCost, week > 0 {
                OMKeyValueRow(label: "Last 7 days", value: OMCostTile.money(week), valueStyle: .figure)
            }
            if let caption = ProviderGridRules.spendCaption(for: service) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.om(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PopoverView.groupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverSurface(.group)
    }

    /// The tooltip under a countdown row: the wall-clock time, always — even inside
    /// the hour, where the row itself drops the parenthesis.
    nonisolated private static func resetTooltip(_ bucket: UsageBucket, now: Date = Date()) -> String {
        ResetCopy.absolute(resetsAt: bucket.resetsAt, now: now).map { "Resets \($0)" } ?? ""
    }

    /// "resets in 2d 4h (Thu 14:15)" for the all-models weekly; nil when unknown.
    private var weeklyReset: String? {
        guard let weekly = weeklyBuckets.first(where: { $0.id == "seven_day" }) ?? weeklyBuckets.first
        else { return nil }
        return ResetCopy.both(resetsAt: weekly.resetsAt, now: Date())
    }

    // A toggle row costs as much space as a ring row, so only fold when there
    // are at least two untouched windows (a single one is shown inline).
    @ViewBuilder
    private var unusedToggle: some View {
        if weeklyRows.showsToggle {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showUnusedWindows.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showUnusedWindows ? 90 : 0))
                    Text(PopoverCopy.unusedWindowsToggle(count: weeklyRows.unusedCount, unfolded: showUnusedWindows))
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.om(.secondary))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - State label with recovery help

/// The provider's state as coloured text (spec § Principles 2: no chips). When there is
/// a way out, the label is a button with a chevron, and clicking it walks the user
/// through fixing the state instead of doing nothing.
private struct ServiceStateLabel: View {
    let service: ServiceSnapshot
    let label: OMColoredText
    /// Whether Antigravity is installed, read with the hook status once per open
    /// (`PopoverView.refreshHookStatus`), never while the view draws.
    let antigravityInstalled: Bool
    @State private var showsStateHelp = false
    /// Claude's Sign in: whether a `claude` is on this Mac, and what the last click did.
    @ObservedObject private var claudeSignIn = ClaudeSignInModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let help = stateHelp {
            Button { showsStateHelp.toggle() } label: { text(showsChevron: true) }
                .buttonStyle(.plain)
                .popover(isPresented: $showsStateHelp, arrowEdge: .bottom) { stateHelpContent(help) }
        } else {
            text(showsChevron: false)
        }
    }

    private func text(showsChevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label.text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.om(label.token))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.om(.secondary))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }

    /// The way out behind the state, as `ProviderStateHelp` decides it.
    private var stateHelp: ProviderStateHelp? {
        ProviderStateHelp.help(
            for: service,
            claudeBinaryFound: claudeSignIn.binaryFound,
            claudeNote: claudeSignIn.note,
            antigravityInstalled: antigravityInstalled
        )
    }

    private func stateHelpContent(_ help: ProviderStateHelp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(help.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let command = help.command {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button(ProviderStateHelp.copyButton) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if let appPath = help.appPath {
                Button(ProviderStateHelp.openAntigravityButton) {
                    NSWorkspace.shared.openApplication(
                        at: URL(fileURLWithPath: appPath),
                        configuration: NSWorkspace.OpenConfiguration()
                    )
                    showsStateHelp = false
                }
                .controlSize(.small)
            }
            if let title = help.linkTitle, let url = help.linkURL {
                Link(title, destination: url)
                    .font(.caption)
            }
            if let claude = help.claude {
                claudeActions(claude)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    /// Claude's way out, as the rule decided it, and the line a click left.
    @ViewBuilder
    private func claudeActions(_ help: ClaudeSignInHelp) -> some View {
        switch help.recovery {
        case .signIn:
            Button(ClaudeSignInCopy.signInButton) {
                Task { await ClaudeSignInModel.shared.signIn() }
            }
            .controlSize(.small)
        case .install:
            Link(ClaudeSignInCopy.installLinkTitle, destination: ClaudeSignInCopy.installURL)
                .font(.caption)
        case .keychainAccess:
            Button(ClaudeSignInCopy.advancedButton) {
                SettingsRoute.shared.pendingTab = SettingsTab.advanced.rawValue
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                showsStateHelp = false
            }
            .controlSize(.small)
        case .noAction:
            EmptyView()
        }
        if let note = help.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(.om(help.noteIsFailure ? .warning : .secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Popover — All") {
    PopoverView(state: AppState.shared, layout: IslandLayoutModel(), navigation: IslandNavigationModel())
}

#Preview("Provider detail") {
    ProviderDetail(
        service: ServiceSnapshot(
            id: "claude",
            displayName: "Claude",
            icon: "sparkles",
            plan: "Max 20x",
            accountLabel: nil,
            buckets: [
                UsageBucket(id: "five_hour", label: "Current session", utilization: 34, resetsAt: Date().addingTimeInterval(2 * 3600), kind: .session),
                UsageBucket(id: "seven_day", label: "All models", utilization: 76, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .weekly),
                UsageBucket(id: "seven_day_opus", label: "Opus only", utilization: 12, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
                UsageBucket(id: "seven_day_fable", label: "Fable only", utilization: 93, resetsAt: Date().addingTimeInterval(3 * 24 * 3600), kind: .modelSpecific),
                UsageBucket(id: "seven_day_sonnet", label: "Sonnet only", utilization: 0, resetsAt: .distantFuture, kind: .modelSpecific),
                UsageBucket(id: "seven_day_cowork", label: "Cowork", utilization: 0, resetsAt: .distantFuture, kind: .modelSpecific),
            ],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25),
            weekCost: 41.37,
            state: .ok,
            stateMessage: nil,
            fetchedAt: Date()
        ),
        mode: .used,
        burn: BurnRatePrediction(secondsToLimit: 65 * 60, percentPerMinute: 1.0, bucketId: "five_hour", isStale: false)
    )
    .padding(OMSpacing.l)
    .frame(width: 450)
}
