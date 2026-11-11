import Foundation

actor ProviderCoordinator {
    /// Every service id `snapshot(...)` can return, one per provider it polls. History
    /// outlives its provider: records from one this build no longer polls stay on disk,
    /// and the dashboard's picker asks this set before offering an id. A provider added
    /// to `snapshot(...)` is added here, and to Settings › Providers, in the same commit.
    static let serviceIDs: Set<String> = ["claude", "anthropic-admin", "codex", "antigravity", "grok", "mistral"]

    func snapshot(
        adminKey: String?,
        betaHeader: String,
        preferAdmin: Bool,
        claudeEnabled: Bool,
        codexEnabled: Bool,
        antigravityEnabled: Bool,
        grokEnabled: Bool,
        // Defaulted so a caller that asks for nothing compiles unchanged; the poll
        // (`AppState.performRefresh`) always passes it.
        mistralEnabled: Bool = false,
        claudeHeld: ServiceSnapshot? = nil
    ) async -> UsageSnapshot {
        let now = Date()

        // Claude switched off is not fetched at all, the way Codex off never was (spec
        // 2026-10-25 § Package 1): no keychain read, no usage call. A poll the cadence holds
        // back shows Claude's last answer instead of asking (spec 2026-11-02 § Cadence).
        async let claudeSnap: ServiceSnapshot? = Self.claudeSnapshot(enabled: claudeEnabled, held: claudeHeld) {
            await ClaudeOAuthProvider(betaHeader: betaHeader).fetch()
        }
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
        async let mistralSnap: ServiceSnapshot? = {
            guard mistralEnabled else { return nil }
            return await MistralProvider.shared.fetch()
        }()
        async let adminSnap: ServiceSnapshot? = {
            guard let key = adminKey, !key.isEmpty else { return nil }
            return await AnthropicAdminProvider(adminKey: key).fetch()
        }()

        let claude = await claudeSnap
        let codex = await codexSnap
        let antigravity = await antigravitySnap
        let grok = await grokSnap
        let mistral = await mistralSnap
        let admin = await adminSnap

        let services = Self.ordered(
            claude: claude, admin: admin, codex: codex, antigravity: antigravity, grok: grok, mistral: mistral,
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
    /// numbers and the admin call worked — then Codex, Antigravity, Grok and Mistral. A
    /// provider that is off is nil and simply absent: with Claude off the admin organisation
    /// leads on its own, whichever way `preferAdmin` points (spec 2026-10-25 § Package 1).
    /// `mistral` is defaulted so the callers that order the earlier providers compile unchanged.
    static func ordered(
        claude: ServiceSnapshot?,
        admin: ServiceSnapshot?,
        codex: ServiceSnapshot?,
        antigravity: ServiceSnapshot?,
        grok: ServiceSnapshot?,
        mistral: ServiceSnapshot? = nil,
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
        if let mistral { services.append(mistral) }
        return services
    }

    /// Claude's answer for one poll: none while Claude is off, the held answer when the
    /// cadence held this poll's fetch back (`ClaudePollCadenceRules.heldAnswer`), a fetch
    /// otherwise.
    static func claudeSnapshot(
        enabled: Bool,
        held: ServiceSnapshot?,
        fetch: () async -> ServiceSnapshot
    ) async -> ServiceSnapshot? {
        guard enabled else { return nil }
        if let held { return held }
        return await fetch()
    }
}
