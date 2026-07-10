import CodexBarCore
import Foundation

/// Antigravity usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// Antigravity replaced the Gemini CLI OAuth path for individual Google accounts after
/// the June 2026 shutdown, so for most personal accounts this is the way to track
/// Gemini quotas. The core probe talks to the local language server of a running
/// Antigravity app / `agy` CLI / IDE extension — no external auth, no processes
/// spawned. Quotas come back as two pools (Gemini models; Claude & GPT models), each
/// with weekly and five-hour windows.
actor AntigravityProvider: UsageProvider {
    /// Singleton so the throttle cache survives across poll cycles.
    static let shared = AntigravityProvider()

    nonisolated let serviceID = "antigravity"

    /// Default for the settings toggle: on when Antigravity (app or CLI) is present.
    static var isAntigravityInstalled: Bool {
        let home = NSHomeDirectory()
        return FileManager.default.fileExists(atPath: "/Applications/Antigravity.app")
            || FileManager.default.fileExists(atPath: home + "/.gemini/antigravity-cli")
            || FileManager.default.fileExists(atPath: home + "/.gemini/antigravity")
    }

    private static let icon = "circle.grid.cross"

    /// Local port-scan probe is cheap, but there's no point re-probing on rapid
    /// re-polls; concurrent callers serialize on the actor.
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
            let status = try await AntigravityStatusProbe(processScope: .ideAndCLI).fetch()
            let usage = try status.toUsageSnapshot()
            return Self.snapshot(from: usage, status: status, at: now)
        } catch {
            // Antigravity not running (the local language server is only reachable
            // while the app/CLI/IDE is up) — stay quiet rather than shouting.
            NSLog("[UT] Antigravity fetch failed: %@", String(describing: error))
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Antigravity",
                icon: Self.icon,
                plan: nil,
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: nil,
                state: .notSignedIn,
                stateMessage: "Antigravity isn't running (\(error.localizedDescription))",
                fetchedAt: now
            )
        }
    }

    private static func snapshot(
        from usage: CodexBarCore.UsageSnapshot,
        status: AntigravityStatusSnapshot,
        at now: Date
    ) -> ServiceSnapshot {
        var buckets: [UsageBucket] = []
        if let b = bucket(from: usage.primary, id: "antigravity_gemini", label: "Gemini models") {
            buckets.append(b)
        }
        if let b = bucket(from: usage.secondary, id: "antigravity_claude_gpt", label: "Claude & GPT models") {
            buckets.append(b)
        }
        for named in usage.extraRateWindows ?? [] {
            guard named.usageKnown, !named.window.isSyntheticPlaceholder else { continue }
            buckets.append(UsageBucket(
                id: "antigravity_\(named.id)",
                label: named.title,
                utilization: named.window.usedPercent,
                resetsAt: named.window.resetsAt ?? .distantFuture,
                kind: kind(for: named.window)
            ))
        }

        NSLog("[UT] Antigravity fetch ok: %d window(s), plan=%@", buckets.count, status.accountPlan ?? "?")
        return ServiceSnapshot(
            id: "antigravity",
            displayName: "Antigravity",
            icon: icon,
            plan: status.accountPlan.map { "Antigravity \($0.capitalized)" } ?? "Antigravity",
            accountLabel: status.accountEmail,
            buckets: buckets,
            extraUsage: nil,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }

    private static func bucket(from window: CodexBarCore.RateWindow?, id: String, label: String) -> UsageBucket? {
        guard let w = window, !w.isSyntheticPlaceholder else { return nil }
        return UsageBucket(
            id: id,
            label: label,
            utilization: w.usedPercent,
            resetsAt: w.resetsAt ?? .distantFuture,
            kind: kind(for: w)
        )
    }

    private static func kind(for w: CodexBarCore.RateWindow) -> BucketKind {
        guard let minutes = w.windowMinutes else { return .other }
        return minutes <= 24 * 60 ? .session : .weekly
    }
}
