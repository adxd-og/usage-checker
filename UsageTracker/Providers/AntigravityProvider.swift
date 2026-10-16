import CodexBarCore
import Foundation

/// Antigravity usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// Antigravity replaced the Gemini CLI OAuth path for individual Google accounts after
/// the June 2026 shutdown, so for most personal accounts this is the way to track
/// Gemini quotas. The core probe talks to the local language server of a running
/// Antigravity app / `agy` CLI / IDE extension — no external auth, no processes
/// spawned. Quotas come back as two pools (Gemini models; Claude & GPT models), each
/// with weekly and five-hour windows; a Pro plan adds per-model pools such as Argon
/// (`buckets(from:)`).
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
            let isNotRunning = Self.isUnreachable(error)
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

    /// "Not running" in the sense that matters here: nothing answered. A closed app
    /// is the obvious case, but a lingering Antigravity process with no language
    /// server behind it looks like a missing CSRF token, an undetectable port or a
    /// timeout — CodexBar's own descriptor lumps those with `.notRunning` too. None of
    /// them is the user's fault, so none earns the red chip; a signed-out CLI, an API
    /// refusal, a parse failure or an account mismatch still does.
    nonisolated static func isUnreachable(_ error: Error) -> Bool {
        if let probe = error as? AntigravityStatusProbeError {
            switch probe {
            case .notRunning, .missingCSRFToken, .portDetectionFailed, .timedOut:
                return true
            case .apiError, .parseFailed, .authenticationRequired, .accountMismatch:
                return false
            }
        }
        // The probe talks to localhost: a transport failure there ("Could not connect
        // to the server", a reset, a timeout) is a port with nobody behind it — the
        // app quit and left its pid file — never a reason to show the red chip.
        if error is URLError { return true }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return [ECONNREFUSED, ECONNRESET, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EPIPE].contains(Int32(nsError.code))
        }
        return false
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
        let mapped = buckets(from: usage)
        NSLog("[UT] Antigravity fetch ok: %d window(s), plan=%@", mapped.count, status.accountPlan ?? "?")
        return ServiceSnapshot(
            id: "antigravity",
            displayName: "Antigravity",
            icon: icon,
            plan: status.accountPlan.map { "Antigravity \($0.capitalized)" } ?? "Antigravity",
            accountLabel: status.accountEmail,
            buckets: mapped,
            extraUsage: nil,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }

    /// The probe's reading as the app's buckets, one rule for both of its paths. Pure, so
    /// the tests hand it the `UsageSnapshot` the probe would.
    ///
    /// Quota summary (the local language server; a window id passes
    /// `AntigravityStatusSnapshot.isQuotaSummaryWindowID`): every window by itself and no
    /// aggregates. Each pool's windows are already there, and an aggregate is the worst
    /// window of its family, a per-model pool included (`summaryBucket`).
    /// Per-model (the web API, older servers): the two pool aggregates, then every named
    /// window with known usage.
    nonisolated static func buckets(from usage: CodexBarCore.UsageSnapshot) -> [UsageBucket] {
        let windows = usage.extraRateWindows ?? []
        let reported = windows.filter { $0.usageKnown && !$0.window.isSyntheticPlaceholder }
        if windows.contains(where: { AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id) }) {
            let labels = poolLabels(reported)
            return reported.map { summaryBucket($0, labels: labels) }
        }
        var aggregates: [UsageBucket] = []
        if let b = bucket(from: usage.primary, id: "antigravity_gemini", label: "Gemini models") {
            aggregates.append(b)
        }
        if let b = bucket(from: usage.secondary, id: "antigravity_claude_gpt", label: "Claude & GPT models") {
            aggregates.append(b)
        }
        return aggregates + reported.map { windowBucket($0) }
    }

    /// A named window as CodexBarCore reports it: its title, its kind from its length.
    private static func windowBucket(_ named: NamedRateWindow) -> UsageBucket {
        UsageBucket(
            id: "antigravity_\(named.id)",
            label: named.title,
            utilization: named.window.usedPercent,
            resetsAt: named.window.resetsAt ?? .distantFuture,
            kind: kind(for: named.window),
            windowLength: windowLength(for: named.window)
        )
    }

    /// The stems of the two pools every plan has. Any other stem is a per-model pool.
    private static let poolStems: Set<String> = [
        "gemini", // the Gemini models pool
        "3p", // the Claude and GPT models pool
    ]

    /// One quota-summary window. A pool's window keeps CodexBarCore's title and its kind
    /// from its length. Any other group is a per-model pool (Argon on Pro plans, since
    /// 2026-10-16). CodexBarCore titles every group after its family, so such a pool's
    /// weekly reads exactly like its family's own. It is named from its stem instead
    /// (`labels`, from `poolLabels`) and is `.modelSpecific`: its own row, never the
    /// headline while a pool is reported. The id stays the wire's, so History keeps the
    /// line it already has.
    private static func summaryBucket(_ named: NamedRateWindow, labels: [String: String]) -> UsageBucket {
        guard let stem = summaryStem(named.id), !poolStems.contains(stem) else {
            return windowBucket(named)
        }
        return UsageBucket(
            id: "antigravity_\(named.id)",
            label: labels[stem] ?? named.title,
            utilization: named.window.usedPercent,
            resetsAt: named.window.resetsAt ?? .distantFuture,
            kind: .modelSpecific,
            windowLength: windowLength(for: named.window)
        )
    }

    /// A summary window's bucket id without the cadence, lowercased and with `_` read as
    /// `-` (as CodexBarCore reads it for the cadence): `antigravity-quota-summary-3p-weekly`
    /// → `3p`. nil outside the quota summary.
    private static func summaryStem(_ id: String) -> String? {
        let prefix = "antigravity-quota-summary-"
        guard AntigravityStatusSnapshot.isQuotaSummaryWindowID(id), id.hasPrefix(prefix) else { return nil }
        let stem = String(id.dropFirst(prefix.count))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard let cadence = ["-weekly", "-5h"].first(where: { stem.hasSuffix($0) }) else { return stem }
        return String(stem.dropLast(cadence.count))
    }

    /// The row name of every per-model pool in one reading, by stem. A name is the stem's
    /// words of four letters or more and words with a digit (`poolLabel`), so `…-argon-wtu`
    /// loses the wire's "wtu". Two pools in the reading that would share a name both keep
    /// every word of their stems, so neither row reads as the other. No model table: a
    /// pool that appears next month is named by the same rule. A stem with no word at all
    /// has no entry; its row keeps CodexBarCore's title, the only name left.
    private static func poolLabels(_ windows: [NamedRateWindow]) -> [String: String] {
        let stems = Set(windows.compactMap { summaryStem($0.id) }).subtracting(poolStems)
        var labels: [String: String] = [:]
        for (label, sharing) in Dictionary(grouping: stems, by: { poolLabel($0, everyWord: false) })
        where !label.isEmpty {
            for stem in sharing {
                labels[stem] = sharing.count > 1 ? poolLabel(stem, everyWord: true) : label
            }
        }
        return labels
    }

    /// A stem's words, each capitalised: only those of four letters or more and those with
    /// a digit, unless `everyWord`. When none of them passes, every word is kept
    /// (`xp-wtu` → "Xp Wtu"), never CodexBarCore's title, which names the family.
    private static func poolLabel(_ stem: String, everyWord: Bool) -> String {
        let words = stem.split(separator: "-")
        let kept = everyWord ? words : words.filter { $0.count >= 4 || $0.contains(where: \.isNumber) }
        return (kept.isEmpty ? words : kept)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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
