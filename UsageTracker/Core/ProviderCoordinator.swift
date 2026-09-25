import Foundation

actor ProviderCoordinator {
    /// Every service id `snapshot(...)` can return, one per provider it polls. History
    /// outlives its provider: records from one this build no longer polls stay on disk,
    /// and the dashboard's picker asks this set before offering an id. A provider added
    /// to `snapshot(...)` is added here, and to Settings › Providers, in the same commit.
    static let serviceIDs: Set<String> = ["claude", "anthropic-admin", "codex", "antigravity", "grok"]

    func snapshot(
        adminKey: String?,
        betaHeader: String,
        preferAdmin: Bool,
        codexEnabled: Bool,
        antigravityEnabled: Bool,
        grokEnabled: Bool
    ) async -> UsageSnapshot {
        let now = Date()

        async let claudeSnap: ServiceSnapshot = ClaudeOAuthProvider(betaHeader: betaHeader).fetch()
        async let codexSnap: ServiceSnapshot? = {
            guard codexEnabled else { return nil }
            return await CodexProvider.shared.fetch()
        }()
        async let antigravitySnap: ServiceSnapshot? = {
            guard antigravityEnabled else { return nil }
            return await AntigravityProvider.shared.fetch()
        }()
        async let grokSnap: ServiceSnapshot? = {
            guard grokEnabled else { return nil }
            return await GrokProvider.shared.fetch()
        }()
        async let adminSnap: ServiceSnapshot? = {
            guard let key = adminKey, !key.isEmpty else { return nil }
            return await AnthropicAdminProvider(adminKey: key).fetch()
        }()

        let claude = await claudeSnap
        let codex = await codexSnap
        let antigravity = await antigravitySnap
        let grok = await grokSnap
        let admin = await adminSnap

        var services: [ServiceSnapshot] = []
        if preferAdmin, let a = admin, a.state == .ok {
            services.append(a)
            services.append(claude)
        } else {
            services.append(claude)
            if let a = admin { services.append(a) }
        }
        if let c = codex { services.append(c) }
        if let a = antigravity { services.append(a) }
        if let g = grok { services.append(g) }

        let firstError = services.compactMap(\.stateMessage).first { _ in true }

        return UsageSnapshot(
            services: services,
            fetchedAt: now,
            isStale: false,
            lastError: firstError
        )
    }
}
