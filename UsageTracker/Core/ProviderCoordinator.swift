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
        claudeEnabled: Bool,
        codexEnabled: Bool,
        antigravityEnabled: Bool,
        grokEnabled: Bool
    ) async -> UsageSnapshot {
        let now = Date()

        // Claude switched off is not fetched at all, the way Codex off never was (spec
        // 2026-10-25 § Package 1): no keychain read, no usage call.
        async let claudeSnap: ServiceSnapshot? = {
            guard claudeEnabled else { return nil }
            return await ClaudeOAuthProvider(betaHeader: betaHeader).fetch()
        }()
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

        let services = Self.ordered(
            claude: claude, admin: admin, codex: codex, antigravity: antigravity, grok: grok,
            preferAdmin: preferAdmin
        )

        let firstError = services.compactMap(\.stateMessage).first { _ in true }

        return UsageSnapshot(
            services: services,
            fetchedAt: now,
            isStale: false,
            lastError: firstError
        )
    }

    /// The poll's services in the order every surface lists them. Claude first and the
    /// Admin API organisation beside it — ahead of Claude when the user prefers the admin
    /// numbers and the admin call worked — then Codex, Antigravity and Grok. A provider
    /// that is off is nil and simply absent: with Claude off the admin organisation leads
    /// on its own, whichever way `preferAdmin` points (spec 2026-10-25 § Package 1).
    static func ordered(
        claude: ServiceSnapshot?,
        admin: ServiceSnapshot?,
        codex: ServiceSnapshot?,
        antigravity: ServiceSnapshot?,
        grok: ServiceSnapshot?,
        preferAdmin: Bool
    ) -> [ServiceSnapshot] {
        var services: [ServiceSnapshot] = []
        if preferAdmin, let admin, admin.state == .ok {
            services.append(admin)
            if let claude { services.append(claude) }
        } else {
            if let claude { services.append(claude) }
            if let admin { services.append(admin) }
        }
        if let codex { services.append(codex) }
        if let antigravity { services.append(antigravity) }
        if let grok { services.append(grok) }
        return services
    }
}
