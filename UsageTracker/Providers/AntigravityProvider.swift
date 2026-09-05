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
///
/// The same quotas also live behind Google's web API, which needs only the OAuth
/// credentials Antigravity already wrote to `~/.antigravity/oauth_creds.json`. That is
/// the fallback when the local server isn't there — a closed app is not a reason to
/// tell the user nothing.
actor AntigravityProvider: UsageProvider {
    /// Singleton so the throttle caches survive across poll cycles.
    static let shared = AntigravityProvider()

    nonisolated let serviceID = "antigravity"

    /// The local probe and the web API, as closures: the tests inject both, so a
    /// test run never scans for a process or opens a socket.
    typealias StatusFetch = @Sendable () async throws -> AntigravityStatusSnapshot

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
    /// The web API is a round trip to Google with a refreshable token behind it, so
    /// it runs an order of magnitude less often than the local probe.
    static let remoteMinInterval: TimeInterval = 300

    private let localFetch: StatusFetch
    private let remoteFetch: StatusFetch

    private var cached: (snapshot: ServiceSnapshot, at: Date)?
    /// The last remote outcome, kept for `remoteMinInterval`. A nil snapshot means
    /// that attempt failed. Caching the *result* rather than just the attempt time
    /// is what stops the tile flipping back to "Not running" 45 seconds after a
    /// perfectly good web reading.
    private var remoteCache: (snapshot: ServiceSnapshot?, at: Date)?

    init(
        localFetch: @escaping StatusFetch = {
            try await AntigravityStatusProbe(processScope: .ideAndCLI).fetch()
        },
        remoteFetch: @escaping StatusFetch = {
            try await AntigravityRemoteUsageFetcher().fetch()
        }
    ) {
        self.localFetch = localFetch
        self.remoteFetch = remoteFetch
    }

    func fetch() async -> ServiceSnapshot {
        await fetch(now: Date())
    }

    /// Injectable clock: the two throttles are the behaviour worth testing.
    func fetch(now: Date) async -> ServiceSnapshot {
        if let cached, now.timeIntervalSince(cached.at) < minFetchInterval {
            return cached.snapshot
        }
        let snapshot = await fetchFresh(now: now)
        cached = (snapshot, now)
        return snapshot
    }

    private func fetchFresh(now: Date) async -> ServiceSnapshot {
        do {
            let status = try await localFetch()
            let usage = try status.toUsageSnapshot()
            return Self.snapshot(from: usage, status: status, at: now)
        } catch {
            // The local language server is only reachable while the app/CLI/IDE is
            // up, so "not running" is the normal quiet state, not a sign-in problem.
            NSLog("[UT] Antigravity fetch failed: %@", String(describing: error))
            let isNotRunning: Bool = {
                if case AntigravityStatusProbeError.notRunning = error { return true }
                return false
            }()
            // Only that quiet state is worth a web call. A signed-out CLI or a parse
            // failure is a different problem, and the web API can't fix either.
            if isNotRunning, let remote = await remoteSnapshot(now: now) {
                return remote
            }
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Antigravity",
                icon: Self.icon,
                plan: nil,
                accountLabel: nil,
                buckets: [],
                extraUsage: nil,
                weekCost: nil,
                state: isNotRunning ? .notRunning : .error,
                stateMessage: isNotRunning
                    ? "Antigravity isn't running"
                    : error.localizedDescription,
                fetchedAt: now
            )
        }
    }

    /// The web API, at most once every `remoteMinInterval`. nil = no reading, either
    /// because the last attempt failed or because this one did; the caller then
    /// returns the plain `.notRunning` snapshot and retention keeps the numbers.
    private func remoteSnapshot(now: Date) async -> ServiceSnapshot? {
        if let remoteCache, now.timeIntervalSince(remoteCache.at) < Self.remoteMinInterval {
            return remoteCache.snapshot
        }
        do {
            let status = try await remoteFetch()
            let usage = try status.toUsageSnapshot()
            let snapshot = Self.snapshot(from: usage, status: status, at: now)
            remoteCache = (snapshot, now)
            NSLog("[UT] Antigravity remote fetch ok: %d window(s)", snapshot.buckets.count)
            return snapshot
        } catch {
            // Not signed in on the web either, or the API said no.
            NSLog("[UT] Antigravity remote fetch failed: %@", String(describing: error))
            remoteCache = (nil, now)
            return nil
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
                kind: kind(for: named.window),
                windowLength: windowLength(for: named.window)
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
            kind: kind(for: w),
            windowLength: windowLength(for: w)
        )
    }

    /// Antigravity mixes five-hour and weekly pools per model group; only the
    /// reported length tells them apart for the pace indicator.
    private static func windowLength(for w: CodexBarCore.RateWindow) -> TimeInterval? {
        w.windowMinutes.map { TimeInterval($0) * 60 }
    }

    private static func kind(for w: CodexBarCore.RateWindow) -> BucketKind {
        guard let minutes = w.windowMinutes else { return .other }
        return minutes <= 24 * 60 ? .session : .weekly
    }
}
