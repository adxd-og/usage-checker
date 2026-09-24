import CodexBarCore
import Foundation

/// Codex (OpenAI) usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// The core fetcher talks to the local Codex CLI's `app-server` over RPC and returns
/// rate windows plus account identity; their `LoginShellPathCache` finds nvm/homebrew
/// installs that a GUI app's bare PATH would miss. All contact with CodexBarCore stays
/// in this file — their `UsageSnapshot`/`UsageProvider` names collide with ours, so
/// their types are always module-qualified.
actor CodexProvider: UsageProvider {
    /// Singleton so the throttle cache survives across poll cycles (the coordinator
    /// would otherwise construct a fresh instance per refresh).
    static let shared = CodexProvider()

    /// The id of every snapshot this provider builds. The popover maps a provider tab
    /// to its agent rows with `AgentSource(rawValue: service.id)`, so this string has
    /// to stay equal to `AgentSource.codex.rawValue` (AgentSourceServiceIDTests).
    static let serviceID = "codex"

    nonisolated var serviceID: String { CodexProvider.serviceID }

    /// Used as the default for the settings toggle: on for machines that have
    /// signed into the Codex CLI at least once, off otherwise.
    static var isCodexInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
    }

    private static let icon = "chevron.left.forwardslash.chevron.right"

    /// Every fetch spawns a Codex CLI process and does an RPC round-trip (2–8 s), so
    /// rapid re-polls (popover opens, settings toggles) get the cached snapshot.
    /// Actor isolation additionally serializes concurrent callers.
    private let minFetchInterval: TimeInterval = 45
    private var cached: (snapshot: ServiceSnapshot, at: Date)?

    func fetch() async -> ServiceSnapshot {
        let now = Date()
        if let cached, now.timeIntervalSince(cached.at) < minFetchInterval {
            return cached.snapshot
        }
        let snapshot = await fetchFresh(now: now)
        cached = (snapshot, now)
        return snapshot
    }

    private func fetchFresh(now: Date) async -> ServiceSnapshot {
        do {
            let usage = try await CodexBarCore.UsageFetcher().loadLatestUsage()
            let localCost = await CodexUsageAggregator.shared.costs(now: now)
            NSLog("[UT] Codex local cost: today $%.2f, 7d $%.2f", localCost.today, localCost.week)
            return Self.snapshot(from: usage, weekCost: localCost.week, at: now)
        } catch {
            // No Codex CLI, signed out, or RPC failure — present as signed-out rather
            // than an error so an enabled-but-unused provider stays quiet in the UI.
            NSLog("[UT] Codex fetch failed: %@", String(describing: error))
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Codex",
                icon: Self.icon,
                plan: nil,
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: nil,
                state: .notSignedIn,
                stateMessage: error.localizedDescription,
                fetchedAt: now
            )
        }
    }

    private static func snapshot(
        from usage: CodexBarCore.UsageSnapshot,
        weekCost: Double,
        at now: Date
    ) -> ServiceSnapshot {
        var buckets: [UsageBucket] = []
        if let b = bucket(from: usage.primary, id: "codex_session") { buckets.append(b) }
        if let b = bucket(from: usage.secondary, id: "codex_weekly") { buckets.append(b) }
        if let b = bucket(from: usage.tertiary, id: "codex_tertiary") { buckets.append(b) }
        for named in usage.extraRateWindows ?? [] {
            guard named.usageKnown, !named.window.isSyntheticPlaceholder else { continue }
            buckets.append(UsageBucket(
                id: "codex_\(named.id)",
                label: named.title,
                utilization: named.window.usedPercent,
                resetsAt: named.window.resetsAt ?? .distantFuture,
                kind: kind(for: named.window),
                windowLength: windowLength(for: named.window)
            ))
        }

        let identity = usage.identity(for: .codex)
        NSLog("[UT] Codex fetch ok: %d window(s), plan=%@", buckets.count, identity?.loginMethod ?? "?")
        return ServiceSnapshot(
            id: CodexProvider.serviceID,
            displayName: "Codex",
            icon: icon,
            plan: identity?.loginMethod.map { "Codex \($0.capitalized)" } ?? "Codex",
            accountLabel: identity?.accountEmail,
            buckets: buckets,
            extraUsage: nil,
            weekCost: weekCost > 0 ? weekCost : nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }

    /// The state message of an identified Codex account that answered with no
    /// rate-limit window at all.
    static let noLimitsMessage = "Codex reported no limits"

    /// CodexBarCore hands back an identified account with no windows when the RPC
    /// answers without them (`emptyCodexUsageSnapshotIfIdentified`). For an account that
    /// never had windows — a credits-only plan — that is the truth and stays `.ok`. For
    /// one that had windows a poll ago it is a gap in the answer, not a change of plan:
    /// `.error`, so retention keeps the old numbers dimmed under a chip instead of
    /// dropping them unflagged.
    static func state(bucketCount: Int, hadWindowsBefore: Bool) -> ServiceState {
        bucketCount == 0 && hadWindowsBefore ? .error : .ok
    }

    /// `state(bucketCount:hadWindowsBefore:)` applied to this poll's Codex entry, before
    /// retention runs. "Before" is what the app is showing (`previous`, which right after
    /// a launch is the seeded file) and the stored reading — not this actor's own memory:
    /// "Forget last known numbers" clears both, and that is the user's way out when a
    /// plan really did lose its windows. Every other service passes through untouched.
    static func flaggingMissingWindows(
        in next: UsageSnapshot,
        previous: UsageSnapshot,
        stored: [String: LastKnownService]
    ) -> UsageSnapshot {
        let id = CodexProvider.serviceID
        let hadWindows = previous.services.contains { $0.id == id && !$0.buckets.isEmpty }
            || !(stored[id]?.buckets.isEmpty ?? true)
        let services = next.services.map { service -> ServiceSnapshot in
            guard service.id == id, service.state == .ok,
                  Self.state(bucketCount: service.buckets.count, hadWindowsBefore: hadWindows) != .ok
            else { return service }
            return ServiceSnapshot(
                id: service.id,
                displayName: service.displayName,
                icon: service.icon,
                plan: service.plan,
                accountLabel: service.accountLabel,
                buckets: service.buckets,
                extraUsage: service.extraUsage,
                weekCost: service.weekCost,
                state: .error,
                stateMessage: Self.noLimitsMessage,
                fetchedAt: service.fetchedAt,
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

    private static func bucket(from window: CodexBarCore.RateWindow?, id: String) -> UsageBucket? {
        // Synthesized placeholders stand in for lanes the provider didn't actually
        // report — rendering them would show a phantom 0% window.
        guard let w = window, !w.isSyntheticPlaceholder else { return nil }
        return UsageBucket(
            id: id,
            label: label(for: w),
            utilization: w.usedPercent,
            resetsAt: w.resetsAt ?? .distantFuture,
            kind: kind(for: w),
            windowLength: windowLength(for: w)
        )
    }

    /// Codex reports 5-hour, weekly and (on the free plan) ~30-day windows; the
    /// id/kind inference in `UsageBucket` only knows Anthropic's shapes, so the
    /// reported length is what makes the pace indicator honest here.
    private static func windowLength(for w: CodexBarCore.RateWindow) -> TimeInterval? {
        w.windowMinutes.map { TimeInterval($0) * 60 }
    }

    private static func label(for w: CodexBarCore.RateWindow) -> String {
        guard let minutes = w.windowMinutes else { return "Usage" }
        if minutes <= 24 * 60 { return "Current session" }
        // Free-plan Codex reports a ~30-day window; don't call that "Weekly".
        if minutes <= 8 * 24 * 60 { return "Weekly" }
        return "Monthly"
    }

    private static func kind(for w: CodexBarCore.RateWindow) -> BucketKind {
        guard let minutes = w.windowMinutes else { return .other }
        return minutes <= 24 * 60 ? .session : .weekly
    }
}
