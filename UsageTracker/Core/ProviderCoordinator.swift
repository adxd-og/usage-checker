import Foundation

actor ProviderCoordinator {
    func snapshot(
        adminKey: String?,
        betaHeader: String,
        preferAdmin: Bool,
        codexEnabled: Bool
    ) async -> UsageSnapshot {
        let now = Date()

        async let claudeSnap: ServiceSnapshot = ClaudeOAuthProvider(betaHeader: betaHeader).fetch()
        async let codexSnap: ServiceSnapshot? = {
            guard codexEnabled else { return nil }
            return await CodexProvider.shared.fetch()
        }()
        async let adminSnap: ServiceSnapshot? = {
            guard let key = adminKey, !key.isEmpty else { return nil }
            return await AnthropicAdminProvider(adminKey: key).fetch()
        }()

        let claude = await claudeSnap
        let codex = await codexSnap
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

        let firstError = services.compactMap(\.stateMessage).first { _ in true }

        return UsageSnapshot(
            services: services,
            fetchedAt: now,
            isStale: false,
            lastError: firstError
        )
    }
}
