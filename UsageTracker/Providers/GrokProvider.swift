import CodexBarCore
import Foundation

/// Grok (xAI) usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// Primary path spawns the Grok CLI (`grok agent stdio`, JSON-RPC) and asks its
/// `x.ai/billing` extension for credit usage over the current billing period. When
/// the CLI is missing or the RPC fails, falls back to the grok.com web billing
/// endpoint authenticated with the bearer token from `~/.grok/auth.json`.
/// CodexBar's browser-cookie import is deliberately not used. All contact with
/// CodexBarCore stays in this file.
actor GrokProvider: UsageProvider {
    /// Singleton so the throttle cache survives across poll cycles.
    static let shared = GrokProvider()

    nonisolated let serviceID = "grok"

    /// Default for the settings toggle: on once the Grok CLI has been signed
    /// into on this machine.
    static var isGrokInstalled: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grok/auth.json")
    }

    private static let icon = "x.circle"

    /// A fetch may spawn a Grok CLI process and do an RPC round-trip, so rapid
    /// re-polls (popover opens, settings toggles) get the cached snapshot.
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
        // 1. CLI RPC — richest data (percent plus billing-period bounds).
        do {
            let usage = try await GrokStatusProbe().fetch()
            return Self.snapshot(from: usage, at: now)
        } catch {
            NSLog("[UT] Grok CLI fetch failed, trying web billing: %@", String(describing: error))
        }
        // 2. Web billing with the auth.json bearer token (percent + reset date).
        do {
            let credentials = try GrokCredentialsStore.load()
            guard !credentials.isExpired else { throw GrokWebBillingError.missingCredentials }
            let webBilling = try await GrokWebBillingFetcher.fetch(credentials: credentials)
            let usage = GrokUsageSnapshot(
                billing: nil,
                webBilling: webBilling,
                credentials: credentials,
                localSummary: nil,
                cliVersion: nil,
                updatedAt: now
            )
            return Self.snapshot(from: usage, at: now)
        } catch {
            // No CLI, signed out, or endpoint failure — present as signed-out
            // rather than an error so an enabled-but-unused provider stays quiet.
            NSLog("[UT] Grok web fetch failed: %@", String(describing: error))
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Grok",
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

    private static func snapshot(from usage: GrokUsageSnapshot, at now: Date) -> ServiceSnapshot {
        let core = usage.toUsageSnapshot()
        var buckets: [UsageBucket] = []
        if let w = core.primary, !w.isSyntheticPlaceholder {
            // The one window Grok reports: credits used in the current billing
            // period. Kind `.weekly` (not `.other`) so the popover renders it —
            // same monthly-window precedent as free-plan Codex.
            buckets.append(UsageBucket(
                id: "grok_credits",
                label: "Credits",
                utilization: w.usedPercent,
                resetsAt: w.resetsAt ?? .distantFuture,
                kind: .weekly
            ))
        }

        let identity = core.identity(for: .grok)
        // OIDC logins already carry a display-ready plan name ("SuperGrok");
        // browser-session auth reports the literal "session", which isn't a plan.
        let plan: String = {
            guard let method = identity?.loginMethod, method.lowercased() != "session" else { return "Grok" }
            return method
        }()
        NSLog("[UT] Grok fetch ok: %d window(s), plan=%@", buckets.count, plan)
        return ServiceSnapshot(
            id: "grok",
            displayName: "Grok",
            icon: icon,
            plan: plan,
            accountLabel: identity?.accountEmail,
            buckets: buckets,
            extraUsage: nil,
            weekCost: nil,
            state: .ok,
            stateMessage: nil,
            fetchedAt: now
        )
    }
}
