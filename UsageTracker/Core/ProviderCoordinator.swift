import Foundation

actor ProviderCoordinator {
    func snapshot(adminKey: String?, betaHeader: String, preferAdmin: Bool) async -> UsageSnapshot {
        let now = Date()

        async let claudeSnap: ServiceSnapshot = ClaudeOAuthProvider(betaHeader: betaHeader).fetch()
        async let adminSnap: ServiceSnapshot? = {
            guard let key = adminKey, !key.isEmpty else { return nil }
            return await AnthropicAdminProvider(adminKey: key).fetch()
        }()

        let claude = await claudeSnap
        let admin = await adminSnap

        var services: [ServiceSnapshot] = []
        if preferAdmin, let a = admin, a.state == .ok {
            services.append(a)
            services.append(claude)
        } else {
            services.append(claude)
            if let a = admin { services.append(a) }
        }

        let firstError = services.compactMap(\.stateMessage).first { _ in true }

        return UsageSnapshot(
            services: services,
            fetchedAt: now,
            isStale: false,
            lastError: firstError
        )
    }
}
