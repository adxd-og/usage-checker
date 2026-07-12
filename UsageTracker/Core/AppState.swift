import Foundation
import SwiftUI

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

    private init() {}

    func bootstrap() {
        refreshNow()
        startTimer()
    }

    /// User-initiated by default (settings toggles, Refresh buttons). A user
    /// request is never silently dropped: mid-flight it's remembered and rerun
    /// once the current poll finishes, and it bypasses the Retry-After backoff
    /// (one deliberate request isn't a hammer — a re-enabled provider used to
    /// stay invisible for up to the backoff/interval because of this). The
    /// timer passes `userInitiated: false` and keeps honoring the backoff.
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
        next = Self.retainingLastGoodServices(previous: snapshot, next: next)

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

        // Back off polling until any server-requested Retry-After elapses (clamped to 5m);
        // a clean fetch clears the backoff.
        if let backoff = next.services.compactMap(\.retryAfter).max(), backoff > 0 {
            nextAllowedRefresh = Date().addingTimeInterval(min(backoff, 300))
        } else {
            nextAllowedRefresh = .distantPast
        }

        UsageNotifier.shared.evaluate(snapshot: next)
        if next.hasAnyData {
            WidgetBridge.publish(next.services, at: next.fetchedAt)
        }
        if let claude = next.services.first(where: { $0.id == "claude" }), claude.state == .ok {
            await HistoryStore.shared.append(snapshot: claude)
            await DashboardState.shared.refreshHistory()
            await DashboardState.shared.refreshDerived()
        }
        NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
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
                id: "claude_weekly_budget",
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
    private static func retainingLastGoodServices(
        previous: UsageSnapshot,
        next: UsageSnapshot
    ) -> UsageSnapshot {
        let services = next.services.map { service -> ServiceSnapshot in
            guard service.state != .ok, service.buckets.isEmpty,
                  let prev = previous.services.first(where: { $0.id == service.id }),
                  !prev.buckets.isEmpty
            else { return service }
            return ServiceSnapshot(
                id: service.id,
                displayName: service.displayName,
                icon: service.icon,
                plan: prev.plan,
                accountLabel: prev.accountLabel,
                buckets: prev.buckets,
                extraUsage: prev.extraUsage,
                weekCost: prev.weekCost,
                state: service.state,
                stateMessage: service.stateMessage,
                fetchedAt: prev.fetchedAt,
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
                self?.refreshNow(userInitiated: false)
            }
        }
    }

    func restartTimer() {
        startTimer()
    }
}
