import Foundation

/// Mistral (spec 2026-11-10 Mistral provider, P1): the plan's Vibe and API allowances from
/// Mistral's billing API, with the API key the vibe CLI keeps. Our own fetch, as for Claude:
/// CodexBarCore's Mistral path imports browser cookies, which this app never does
/// (`GrokProvider`). Local usage from `~/.vibe/logs` is P2's, under the same service id.
actor MistralProvider: UsageProvider {
    /// Singleton so the 60 s cache survives across poll cycles.
    static let shared = MistralProvider()

    static let serviceID = "mistral"
    nonisolated var serviceID: String { Self.serviceID }

    /// The SF Symbol where the bundled mark does not resolve (`ProviderIconView`, Decisions 3).
    static let icon = "cat"

    /// Two billing calls per fetch: rapid re-polls (the island opening, a switch flipped) get
    /// the last answer, as Grok's do for 45 s. Every answer is kept, a failure too.
    static let minFetchInterval: TimeInterval = 60

    private let credentials: MistralCredentialReader
    private let fetcher: MistralBillingFetcher
    private var cached: (snapshot: ServiceSnapshot, at: Date)?

    init(credentials: MistralCredentialReader = .live, fetcher: MistralBillingFetcher = .live) {
        self.credentials = credentials
        self.fetcher = fetcher
    }

    /// Default for the Settings switch (spec § States): on only where vibe has a home.
    static var isVibeInstalled: Bool {
        vibeHomeExists(home: FileManager.default.homeDirectoryForCurrentUser) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    nonisolated static func vibeHomeExists(home: URL, fileExists: (String) -> Bool) -> Bool {
        fileExists(home.appendingPathComponent(".vibe").path)
    }

    func fetch() async -> ServiceSnapshot {
        await fetch(now: Date())
    }

    func fetch(now: Date) async -> ServiceSnapshot {
        if let cached, now.timeIntervalSince(cached.at) < Self.minFetchInterval {
            return cached.snapshot
        }
        let snapshot = await fetchFresh(now: now)
        cached = (snapshot, now)
        return snapshot
    }

    private func fetchFresh(now: Date) async -> ServiceSnapshot {
        guard let key = credentials.read() else { return Self.snapshot(result: nil, now: now) }
        let snapshot = Self.snapshot(result: await fetcher.fetch(apiKey: key), now: now)
        // The state and a count, never the key or a body.
        NSLog("[UT] Mistral fetch: %@, %d window(s)", snapshot.state.rawValue, snapshot.buckets.count)
        return snapshot
    }

    /// The answer as the app shows it (spec § States). `result` nil: no key anywhere. Failed
    /// states carry no windows; retention brings the last-known ones back, dimmed.
    nonisolated static func snapshot(result: Result<MistralBilling, MistralBillingError>?, now: Date) -> ServiceSnapshot {
        guard let result else {
            return make(state: .notSignedIn, message: MistralCopy.notSignedInMessage, reason: .notFound, now: now)
        }
        switch result {
        case .success(let billing):
            let plan = MistralCopy.planName(billing.planName)
            switch billing.budget {
            case .entries(let entries):
                return make(plan: plan, buckets: MistralBudgetRules.buckets(from: entries), now: now)
            case .noBilling:
                return make(plan: plan, now: now)
            case .noUsageAccess:
                return make(plan: plan, state: .error, message: MistralCopy.noUsageAccessMessage, now: now)
            }
        case .failure(.unauthorized):
            return make(state: .notSignedIn, message: MistralCopy.signedOutMessage, reason: .expired, now: now)
        case .failure(.rateLimited(let retryAfter)):
            return make(state: .error, message: MistralCopy.rateLimitedMessage, retryAfter: retryAfter ?? 60, now: now)
        case .failure(.badStatus(let code)):
            return make(state: .error, message: HTTPClientError.badStatus(code, body: "").localizedDescription, now: now)
        case .failure(.transport(let words)):
            return make(state: .error, message: words, now: now)
        case .failure(.decoding(let words)):
            return make(state: .error, message: HTTPClientError.decoding(words).localizedDescription, now: now)
        }
    }

    private nonisolated static func make(
        plan: String? = nil,
        buckets: [UsageBucket] = [],
        state: ServiceState = .ok,
        message: String? = nil,
        reason: SignedOutReason? = nil,
        retryAfter: TimeInterval? = nil,
        now: Date
    ) -> ServiceSnapshot {
        ServiceSnapshot(
            id: serviceID,
            displayName: MistralCopy.displayName,
            icon: icon,
            plan: plan,
            accountLabel: nil,
            buckets: buckets,
            extraUsage: nil,
            weekCost: nil,
            state: state,
            stateMessage: message,
            fetchedAt: now,
            retryAfter: retryAfter,
            signedOutReason: reason
        )
    }
}
