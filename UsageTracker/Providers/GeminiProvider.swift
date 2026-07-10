import CodexBarCore
import Foundation

/// Gemini usage adapted from CodexBarCore (steipete/CodexBar, MIT).
///
/// The core probe is a plain HTTPS call to the Cloud Code quota API using the Gemini
/// CLI's OAuth credentials (`~/.gemini/oauth_creds.json`, refreshed automatically).
/// Quotas come back per model and are grouped into daily tiers: Pro, Flash, Flash Lite.
/// API-key and Vertex AI auth don't expose quotas and surface as signed-out.
actor GeminiProvider: UsageProvider {
    /// Singleton so the throttle cache survives across poll cycles.
    static let shared = GeminiProvider()

    nonisolated let serviceID = "gemini"

    /// Default for the settings toggle: on once the Gemini CLI has signed in
    /// (the OAuth credentials file exists), off otherwise. `@AppStorage` keeps
    /// re-evaluating the default until the user touches the toggle, so signing
    /// in later flips this on by itself.
    static var isGeminiSignedIn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gemini/oauth_creds.json")
    }

    private static let icon = "diamond"

    /// The probe is one HTTPS round-trip (with an occasional token refresh), but the
    /// quotas are daily — rapid re-polls can safely serve the cached snapshot.
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
            let status = try await GeminiStatusProbe().fetch()
            return Self.snapshot(from: status, at: now)
        } catch {
            // Gemini CLI missing, signed out, or an unsupported auth type (API key /
            // Vertex AI) — stay quiet in the UI rather than shouting an error.
            NSLog("[UT] Gemini fetch failed: %@", String(describing: error))
            return ServiceSnapshot(
                id: serviceID,
                displayName: "Gemini",
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

    private static func snapshot(from status: GeminiStatusSnapshot, at now: Date) -> ServiceSnapshot {
        // Their tier grouping (Pro primary, Flash secondary, Flash Lite tertiary) is a
        // stable contract; only the labels are ours. All Gemini windows are daily.
        let usage = status.toUsageSnapshot()
        var buckets: [UsageBucket] = []
        if let b = bucket(from: usage.primary, id: "gemini_pro", label: "Pro (daily)") { buckets.append(b) }
        if let b = bucket(from: usage.secondary, id: "gemini_flash", label: "Flash (daily)") { buckets.append(b) }
        if let b = bucket(from: usage.tertiary, id: "gemini_flash_lite", label: "Flash Lite (daily)") { buckets.append(b) }

        NSLog("[UT] Gemini fetch ok: %d window(s), plan=%@", buckets.count, status.accountPlan ?? "?")
        return ServiceSnapshot(
            id: "gemini",
            displayName: "Gemini",
            icon: icon,
            plan: status.accountPlan.map { "Gemini \($0.capitalized)" } ?? "Gemini",
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
            kind: .modelSpecific
        )
    }
}
