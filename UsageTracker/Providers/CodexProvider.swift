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

    nonisolated let serviceID = "codex"

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
                kind: kind(for: named.window)
            ))
        }

        let identity = usage.identity(for: .codex)
        NSLog("[UT] Codex fetch ok: %d window(s), plan=%@", buckets.count, identity?.loginMethod ?? "?")
        return ServiceSnapshot(
            id: "codex",
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

    private static func bucket(from window: CodexBarCore.RateWindow?, id: String) -> UsageBucket? {
        // Synthesized placeholders stand in for lanes the provider didn't actually
        // report — rendering them would show a phantom 0% window.
        guard let w = window, !w.isSyntheticPlaceholder else { return nil }
        return UsageBucket(
            id: id,
            label: label(for: w),
            utilization: w.usedPercent,
            resetsAt: w.resetsAt ?? .distantFuture,
            kind: kind(for: w)
        )
    }

    private static func label(for w: CodexBarCore.RateWindow) -> String {
        guard let minutes = w.windowMinutes else { return "Usage" }
        return minutes <= 24 * 60 ? "Current session" : "Weekly"
    }

    private static func kind(for w: CodexBarCore.RateWindow) -> BucketKind {
        guard let minutes = w.windowMinutes else { return .other }
        return minutes <= 24 * 60 ? .session : .weekly
    }
}
