import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isLoading: Bool = false

    private let coordinator = ProviderCoordinator()
    private var inflight: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var lastRefreshAt: Date = .distantPast
    private var nextAllowedRefresh: Date = .distantPast
    /// A user request that arrived while a poll was in flight — run one more
    /// poll right after instead of silently dropping it (multiple requests
    /// coalesce into a single rerun).
    private var pendingUserRefresh = false
    /// Polling while the Mac sleeps or the screen is locked is pure waste — the
    /// menu bar isn't visible, and some providers spawn CLI subprocesses per poll.
    private var systemAsleep = false
    private var screenLocked = false
    private var isSuspended: Bool { systemAsleep || screenLocked }
    private var suspensionObservers: [NSObjectProtocol] = []
    /// Last successful readings from disk — the source `retainingLastGoodServices`
    /// falls back to when this session has never seen a provider succeed.
    private var lastKnown: [String: LastKnownService] = [:] {
        didSet { lastKnownServiceIDs = Set(lastKnown.keys) }
    }
    /// Which services have a stored reading. Published so Settings → Providers offers
    /// "Forget last known numbers" only where there is something to forget.
    @Published private(set) var lastKnownServiceIDs: Set<String> = []
    /// The last dollars `StatusCosts` produced. The poll refreshes them; an agent
    /// starting a tool reuses them, because it did not change what you spent today.
    private var lastCosts: [String: StatusFileWriter.CostEntry] = [:]
    /// Keeps `status.json` current between polls. `$sessions` rather than the store's
    /// `onNeedsYou` / `onDone` hooks: those two belong to `UsageNotifier`, and a
    /// session moving from working to idle still changes what the file says.
    private var agentObserver: AnyCancellable?
    /// One trailing write is pending, so the throttle can never swallow the last change.
    private var statusWriteScheduled = false

    private init() {}

    func bootstrap() {
        observeSystemState()
        // Package 1's AgentChannel delivers hook events on the main actor. The router
        // registers a held PermissionRequest with the broker before the session store
        // applies it (see AgentEventRouter for why the order matters).
        AgentChannel.shared.onEvent = { event, reply in
            AgentEventRouter.handle(event, reply: reply, store: AgentSessionStore.shared, broker: PermissionBroker.shared)
        }
        observeAgentSessions()
        seedFromLastKnown()
        refreshNow()
        startTimer()
    }

    /// The popover opened right after launch was empty for a second — and for a
    /// provider that is closed, empty for good. Seed from disk first: the numbers
    /// are last-known, flagged stale, and the first poll replaces them.
    private func seedFromLastKnown() {
        Task { [weak self] in
            let stored = await LastKnownStore.shared.load()
            await MainActor.run {
                guard let self else { return }
                self.lastKnown = stored
                // The poll started in the same turn may already have landed; fresh
                // data always wins over the file.
                guard !stored.isEmpty, !self.snapshot.hasAnyData else { return }
                self.snapshot = Self.seededSnapshot(from: stored, enabledServiceIDs: self.enabledServiceIDs)
            }
        }
    }

    /// The providers this launch will actually poll, by service id — the same
    /// decisions `performRefresh` hands `ProviderCoordinator.snapshot`, read one turn
    /// earlier. The file remembers every provider that ever reported, so without this
    /// a provider the user has since switched off flashes back onto the All tab at
    /// launch and disappears when the first poll lands.
    private var enabledServiceIDs: Set<String> {
        // Claude is not behind a toggle: the coordinator always fetches it.
        var ids: Set<String> = ["claude"]
        let settings = SettingsStore.shared
        if settings.codexProviderEnabled { ids.insert("codex") }
        if settings.geminiProviderEnabled { ids.insert("gemini") }
        if settings.antigravityProviderEnabled { ids.insert("antigravity") }
        if settings.grokProviderEnabled { ids.insert("grok") }
        // The admin provider exists only while there is a key to call it with.
        if let key = KeychainStore.loadAdminKey(), !key.isEmpty { ids.insert("anthropic-admin") }
        return ids
    }

    /// Stored readings as a snapshot: the numbers, no state message, and the quiet
    /// `.notRunning` chip — nothing has been polled yet this session. `fetchedAt` is
    /// the newest stored reading, so the header says "Updated 3h ago" rather than
    /// claiming the app just refreshed.
    ///
    /// `enabledServiceIDs` is the set this launch will poll; a stored provider outside
    /// it is dropped rather than shown for a second. nil means "don't filter" — the
    /// seeding call always passes a set, and the default keeps the rule callable on
    /// its own terms in a test.
    nonisolated static func seededSnapshot(
        from stored: [String: LastKnownService],
        enabledServiceIDs: Set<String>? = nil
    ) -> UsageSnapshot {
        let stored = enabledServiceIDs.map { enabled in
            stored.filter { enabled.contains($0.key) }
        } ?? stored
        guard !stored.isEmpty else { return .empty }
        let services = stored
            .sorted { ($0.value.order, $0.key) < ($1.value.order, $1.key) }
            .map { pair in
                ServiceSnapshot(
                    id: pair.key,
                    displayName: pair.value.displayName,
                    icon: pair.value.icon,
                    plan: pair.value.plan,
                    accountLabel: pair.value.accountLabel,
                    buckets: pair.value.buckets,
                    extraUsage: pair.value.extraUsage,
                    weekCost: pair.value.weekCost,
                    state: .notRunning,
                    stateMessage: nil,
                    fetchedAt: pair.value.fetchedAt
                )
            }
        return UsageSnapshot(
            services: services,
            fetchedAt: services.map(\.fetchedAt).max() ?? .distantPast,
            isStale: true,
            lastError: nil
        )
    }

    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        // @Sendable because NotificationCenter hands the block to its own queue;
        // it captures only two Bools and a weak main-actor reference.
        func handler(asleep: Bool? = nil, locked: Bool? = nil) -> @Sendable (Notification) -> Void {
            { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setSuspension(asleep: asleep, locked: locked)
                }
            }
        }
        suspensionObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                  queue: .main, using: handler(asleep: true)),
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                  queue: .main, using: handler(asleep: false)),
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                    queue: .main, using: handler(locked: true)),
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                    queue: .main, using: handler(locked: false)),
        ]
    }

    private func setSuspension(asleep: Bool?, locked: Bool?) {
        let wasSuspended = isSuspended
        if let asleep { systemAsleep = asleep }
        if let locked { screenLocked = locked }
        // Coming back from sleep/lock: the data on screen is stale — refresh
        // right away instead of waiting out the remainder of the poll interval.
        if wasSuspended && !isSuspended {
            refreshNow(userInitiated: false)
        }
    }

    /// User-initiated by default (settings toggles, Refresh buttons). A user
    /// request is never silently dropped: mid-flight it's remembered and rerun
    /// once the current poll finishes, and it bypasses the Retry-After backoff
    /// (one deliberate request isn't a hammer — a re-enabled provider used to
    /// stay invisible for up to the backoff/interval because of this). The
    /// timer passes `userInitiated: false` and keeps honoring the backoff.
    /// Opening the popover is not a reason to ignore a 429 backoff or to hit the
    /// usage endpoint again seconds after the last poll: opening and closing it a
    /// few times while debugging is exactly how the endpoint was driven into a
    /// burst of 429s on 2026-09-03. Ten seconds keeps "open = fresh" true in
    /// practice (the timer runs every 60 s) without letting clicks multiply calls.
    /// The window `applyPayAsYouGo` invents for an account that reports none of its
    /// own. Named here because `StatusFileWriter` has to tell it apart from a window a
    /// provider actually reported — a budget Omelette made up is not evidence of a
    /// subscription.
    nonisolated static let payAsYouGoBudgetBucketID = "claude_weekly_budget"

    nonisolated static let popoverRefreshFloor: TimeInterval = 10

    nonisolated static func shouldRefreshOnPopoverOpen(lastRefreshAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastRefreshAt) >= popoverRefreshFloor
    }

    /// The popover's entry point: a poll only if the last one is old enough, and
    /// even then subject to the server's Retry-After like the timer's polls.
    func refreshForPopover() {
        guard Self.shouldRefreshOnPopoverOpen(lastRefreshAt: lastRefreshAt, now: Date()) else { return }
        refreshNow(userInitiated: false)
    }

    func refreshNow(userInitiated: Bool = true) {
        if inflight != nil {
            if userInitiated { pendingUserRefresh = true }
            return
        }
        let now = Date()
        if !userInitiated {
            // Respect a server Retry-After from a previous 429 instead of hammering the endpoint.
            if now < nextAllowedRefresh { return }
            if now.timeIntervalSince(lastRefreshAt) < 0.5 { return }
        }
        startRefresh(at: now)
    }

    private func startRefresh(at now: Date) {
        lastRefreshAt = now
        inflight = Task { [weak self] in
            await self?.performRefresh()
            await MainActor.run {
                guard let self else { return }
                self.inflight = nil
                if self.pendingUserRefresh {
                    self.pendingUserRefresh = false
                    self.startRefresh(at: Date())
                }
            }
        }
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        // Cheap daily no-op: keeps CLI cost rates current from models.dev.
        await ModelsDevPricing.refreshIfStale()

        let admin = KeychainStore.loadAdminKey()
        let beta = SettingsStore.shared.anthropicBetaHeader
        let preferAdmin = SettingsStore.shared.preferAdminWhenAvailable
        var next = await coordinator.snapshot(
            adminKey: admin,
            betaHeader: beta,
            preferAdmin: preferAdmin,
            codexEnabled: SettingsStore.shared.codexProviderEnabled,
            geminiEnabled: SettingsStore.shared.geminiProviderEnabled,
            antigravityEnabled: SettingsStore.shared.antigravityProviderEnabled,
            grokEnabled: SettingsStore.shared.grokProviderEnabled
        )
        next = await Self.applyPayAsYouGo(to: next)
        next = Self.retainingLastGoodServices(previous: snapshot, next: next, stored: lastKnown)

        // A failed or empty poll (network blip, transient API error) must not wipe the
        // last-known usage from the menu bar. Keep the previous data and flag it stale;
        // only replace when we have fresh data or never had any.
        if next.hasAnyData || !snapshot.hasAnyData {
            snapshot = next
        } else {
            snapshot = UsageSnapshot(
                services: snapshot.services,
                fetchedAt: snapshot.fetchedAt,
                isStale: true,
                lastError: next.lastError
            )
        }

        // The disk copy, for the next launch and for the fallback above. Only ok,
        // non-empty readings are written; the store skips unchanged numbers.
        await LastKnownStore.shared.remember(snapshot.services)
        lastKnown = await LastKnownStore.shared.load()

        // Back off polling until any server-requested Retry-After elapses (clamped to 5m);
        // a clean fetch clears the backoff.
        if let backoff = next.services.compactMap(\.retryAfter).max(), backoff > 0 {
            nextAllowedRefresh = Date().addingTimeInterval(min(backoff, 300))
        } else {
            nextAllowedRefresh = .distantPast
        }

        if next.hasAnyData {
            WidgetBridge.publish(next.services, at: next.fetchedAt)
        }
        // Every healthy provider gets a history point, not just Claude — the
        // dashboard's charts and the pace prediction are per service now.
        var recordedAny = false
        for service in next.services where service.state == .ok {
            await HistoryStore.shared.append(snapshot: service)
            recordedAny = true
        }
        if recordedAny {
            await DashboardState.shared.refreshDerived()
        }
        // Deliberately after the history append: the pace alert predicts from a slice
        // that has to include this poll's data point to be current.
        await UsageNotifier.shared.evaluate(snapshot: next)
        NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
        await scanAgentsPassively()
        publishStatusFileAfterPoll()
    }

    /// Sessions no hook has spoken for, read from the CLIs' own logs. Riding the poll
    /// tick means it inherits the 60-second cadence and, more importantly, the
    /// sleep/lock suspension — a laptop with the lid shut walks no log trees. The scan
    /// itself is file I/O over two directory trees, so it runs off the main actor and
    /// only the merge comes back.
    private func scanAgentsPassively() async {
        let claudeProjects = AgentPaths.claudeProjectsURL
        let codexSessions = AgentPaths.codexSessionsURL
        let scanned = await Task.detached(priority: .utility) {
            PassiveSessionScanner.scan(claudeProjects: claudeProjects, codexSessions: codexSessions)
        }.value
        AgentSessionStore.shared.mergePassive(scanned)
        AgentSessionStore.shared.pruneStale()
    }

    /// `status.json` for the `omelette` CLI: the numbers this poll produced, plus the
    /// dollars from the cost logs. Gathering and writing both happen off the main
    /// actor — the aggregators are actors and their scan is file I/O — so a slow log
    /// tree delays the file, never the poll or the menu bar.
    private func publishStatusFileAfterPoll() {
        let ids = Set(snapshot.services.map(\.id))
        Task { [weak self] in
            let costs = await StatusCosts.gather(serviceIDs: ids)
            await MainActor.run {
                guard let self else { return }
                self.lastCosts = costs
                self.publishStatusFile(costs: costs)
            }
        }
    }

    /// The agent list changes far more often than the poll does, and the CLI's flag
    /// count comes from it. `@Published` sends on the main actor because the store is
    /// `@MainActor`, which is what makes `assumeIsolated` true here rather than hopeful.
    private func observeAgentSessions() {
        agentObserver = AgentSessionStore.shared.$sessions
            .sink { _ in
                MainActor.assumeIsolated {
                    AppState.shared.publishStatusFile(costs: AppState.shared.lastCosts)
                }
            }
    }

    /// Writes the file, or schedules one write for when the throttle allows it — the
    /// last change has to reach disk, or a status line spends the rest of the day
    /// showing a flag for an agent that stopped waiting an hour ago.
    private func publishStatusFile(costs: [String: StatusFileWriter.CostEntry]) {
        let built = StatusFileWriter.build(
            services: snapshot.services,
            costs: costs,
            agents: StatusFileWriter.AgentSummary(sessions: AgentSessionStore.shared.sessions),
            now: Date()
        )
        Task { [weak self] in
            let wrote = await StatusFileWriter.shared.write(built)
            guard !wrote else { return }
            await MainActor.run { self?.scheduleTrailingStatusWrite() }
        }
    }

    private func scheduleTrailingStatusWrite() {
        guard !statusWriteScheduled else { return }
        statusWriteScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(StatusFileWriter.minimumInterval * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.statusWriteScheduled = false
                self.publishStatusFile(costs: self.lastCosts)
            }
        }
    }

    /// Pay-as-you-go accounts (Enterprise API billing) get no rate-limit windows from
    /// the usage endpoint, which used to leave the menu bar empty. Give them a
    /// presence anyway: local CLI spend as `weekCost` ($ pill + "Last 7 days" row),
    /// and — when the user sets a weekly budget — a synthetic bucket that lights up
    /// the whole percentage UI: bars, hero header, threshold notifications.
    private static func applyPayAsYouGo(to snapshot: UsageSnapshot) async -> UsageSnapshot {
        guard let idx = snapshot.services.firstIndex(where: { $0.id == "claude" && $0.state == .ok }) else {
            return snapshot
        }
        var claude = snapshot.services[idx]
        // Debug hook: `defaults write com.usagetracker.app debugForcePAYG -bool true`
        // simulates a windowless account on a subscription machine.
        if UserDefaults.standard.bool(forKey: "debugForcePAYG") {
            claude = Self.strippingBuckets(claude)
        }
        guard claude.buckets.isEmpty else { return snapshot }

        await JSONLAggregator.shared.refresh()
        let breakdown = await JSONLAggregator.shared.breakdown()
        guard breakdown.weekCost > 0 else { return snapshot }

        var buckets: [UsageBucket] = []
        let budget = SettingsStore.shared.claudeWeeklyBudgetUSD
        if budget > 0 {
            buckets.append(UsageBucket(
                id: Self.payAsYouGoBudgetBucketID,
                label: "Weekly budget",
                utilization: breakdown.weekCost / budget * 100,
                resetsAt: .distantFuture,
                kind: .weekly
            ))
        }
        NSLog("[UT] PAYG mode: weekCost $%.2f, budget %@", breakdown.weekCost,
              budget > 0 ? String(format: "%.0f%%", breakdown.weekCost / budget * 100) : "off")

        var services = snapshot.services
        services[idx] = ServiceSnapshot(
            id: claude.id,
            displayName: claude.displayName,
            icon: claude.icon,
            plan: claude.plan,
            accountLabel: claude.accountLabel,
            buckets: buckets,
            extraUsage: claude.extraUsage,
            weekCost: breakdown.weekCost,
            state: .ok,
            stateMessage: claude.stateMessage,
            fetchedAt: claude.fetchedAt,
            retryAfter: claude.retryAfter
        )
        return UsageSnapshot(
            services: services,
            fetchedAt: snapshot.fetchedAt,
            isStale: snapshot.isStale,
            lastError: snapshot.lastError
        )
    }

    /// Per-service last-good retention. The whole-snapshot keep-on-failure logic
    /// stopped helping once there were several providers: with Codex healthy, a
    /// rate-limited Claude replaced its bars with a bare error tile. Instead, a
    /// service that comes back failed keeps its previous data (bars, plan, costs)
    /// alongside the error state — the badge says what's wrong, the numbers stay.
    ///
    /// Two sources, in order: this session's own last good poll, then the file. The
    /// file is what carries Antigravity's numbers through a relaunch with the app
    /// closed, which nothing did before.
    nonisolated static func retainingLastGoodServices(
        previous: UsageSnapshot,
        next: UsageSnapshot,
        stored: [String: LastKnownService] = [:]
    ) -> UsageSnapshot {
        let services = next.services.map { service -> ServiceSnapshot in
            guard service.state != .ok, service.buckets.isEmpty else { return service }
            let source: LastKnownService? = {
                if let prev = previous.services.first(where: { $0.id == service.id }), !prev.buckets.isEmpty {
                    return LastKnownService(from: prev, order: 0)
                }
                guard let entry = stored[service.id], !entry.buckets.isEmpty else { return nil }
                return entry
            }()
            guard let source else { return service }
            return ServiceSnapshot(
                id: service.id,
                displayName: service.displayName,
                icon: service.icon,
                plan: source.plan,
                accountLabel: source.accountLabel,
                buckets: source.buckets,
                extraUsage: source.extraUsage,
                weekCost: source.weekCost,
                state: service.state,
                stateMessage: service.stateMessage,
                fetchedAt: source.fetchedAt,
                retryAfter: service.retryAfter
            )
        }
        return UsageSnapshot(
            services: services,
            fetchedAt: next.fetchedAt,
            isStale: next.isStale,
            lastError: next.lastError
        )
    }

    private static func strippingBuckets(_ s: ServiceSnapshot) -> ServiceSnapshot {
        ServiceSnapshot(
            id: s.id, displayName: s.displayName, icon: s.icon, plan: s.plan,
            accountLabel: s.accountLabel, buckets: [], extraUsage: s.extraUsage,
            weekCost: s.weekCost, state: s.state, stateMessage: s.stateMessage,
            fetchedAt: s.fetchedAt, retryAfter: s.retryAfter
        )
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(15, SettingsStore.shared.refreshIntervalSeconds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                } catch {
                    return // cancelled
                }
                guard !Task.isCancelled else { return }
                guard let self, !self.isSuspended else { continue }
                self.refreshNow(userInitiated: false)
            }
        }
    }

    /// Settings → Providers → "Forget last known numbers". The stored entry and the
    /// dimmed numbers on screen go in the same turn: a button whose effect only shows
    /// up after the next poll reads as broken. The file write is the slow half and
    /// rides its own task.
    func forgetLastKnown(serviceID: String) {
        lastKnown.removeValue(forKey: serviceID)
        snapshot = Self.droppingRetained(serviceID: serviceID, from: snapshot)
        Task { await LastKnownStore.shared.forget(serviceID: serviceID) }
    }

    /// The pure half: the named service loses everything it was only showing because
    /// it was retained — the windows, the plan, the account, the costs. A live service
    /// keeps all of it; so does every other service in the snapshot. The state and its
    /// message stay, because the chip still has to say why the provider went quiet.
    nonisolated static func droppingRetained(serviceID: String, from snapshot: UsageSnapshot) -> UsageSnapshot {
        let services = snapshot.services.map { service -> ServiceSnapshot in
            guard service.id == serviceID, service.isRetained else { return service }
            return ServiceSnapshot(
                id: service.id,
                displayName: service.displayName,
                icon: service.icon,
                plan: nil,
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: nil,
                state: service.state,
                stateMessage: service.stateMessage,
                fetchedAt: service.fetchedAt,
                retryAfter: service.retryAfter
            )
        }
        return UsageSnapshot(
            services: services,
            fetchedAt: snapshot.fetchedAt,
            isStale: snapshot.isStale,
            lastError: snapshot.lastError
        )
    }

    func restartTimer() {
        startTimer()
    }
}
