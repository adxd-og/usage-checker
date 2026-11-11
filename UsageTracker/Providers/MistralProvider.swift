import Foundation

/// Mistral (spec 2026-11-10 Mistral provider, P1): the plan's Vibe and API allowances from
/// Mistral's billing API, with the API key the vibe CLI keeps. Our own fetch, as for Claude:
/// CodexBarCore's Mistral path imports browser cookies, which this app never does
/// (`GrokProvider`). Local usage from `~/.vibe/logs` is P2's, under the same service id.
actor MistralProvider: UsageProvider {
    /// Singleton so the 60 s cache survives across poll cycles. Its week of local dollars
    /// comes from vibe's session logs (spec § Local usage (P2)).
    static let shared = MistralProvider(weekCost: { await VibeUsageAggregator.shared.refreshedWeekCost(now: $0) })

    static let serviceID = "mistral"
    nonisolated var serviceID: String { Self.serviceID }

    /// The SF Symbol where the bundled mark does not resolve (`ProviderIconView`, Decisions 3).
    static let icon = "cat"

    /// Two billing calls per fetch: rapid re-polls (the island opening, a switch flipped) get
    /// the last answer, as Grok's do for 45 s. Every answer is kept, a failure too.
    static let minFetchInterval: TimeInterval = 60

    /// The local log's last seven days of dollars as of a moment: `VibeUsageAggregator` for
    /// `shared`; nothing for a provider a test builds, which then reads no log at all.
    typealias WeekCost = @Sendable (Date) async -> Double

    private let credentials: MistralCredentialReader
    private let fetcher: MistralBillingFetcher
    private let weekCost: WeekCost
    private var cached: (snapshot: ServiceSnapshot, at: Date)?

    init(
        credentials: MistralCredentialReader = .live,
        fetcher: MistralBillingFetcher = .live,
        weekCost: @escaping WeekCost = { _ in 0 }
    ) {
        self.credentials = credentials
        self.fetcher = fetcher
        self.weekCost = weekCost
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
        // Local spend from ~/.vibe/logs, folded into this poll as Grok's is, and read before
        // the key: a signed-out vibe's spend is still real (spec § Local usage (P2), Dollars).
        let week = await weekCost(now)
        guard let key = credentials.read() else { return Self.snapshot(result: nil, now: now, weekCost: week) }
        let snapshot = Self.snapshot(result: await fetcher.fetch(apiKey: key), now: now, weekCost: week)
        // The state, a count and the local dollars, never the key or a body.
        NSLog(
            "[UT] Mistral fetch: %@, %d window(s), local 7d $%.2f",
            snapshot.state.rawValue, snapshot.buckets.count, week
        )
        return snapshot
    }

    /// The answer as the app shows it (spec § States). `result` nil: no key anywhere. Failed
    /// states carry no windows; retention brings the last-known ones back, dimmed. `weekCost`,
    /// the local log's last seven days, rides every answer, a failed one too; it is always an
    /// API-list-price equivalent (`CostCopy.alwaysAPIEquivalent`).
    nonisolated static func snapshot(
        result: Result<MistralBilling, MistralBillingError>?, now: Date, weekCost: Double = 0
    ) -> ServiceSnapshot {
        let week = weekCost > 0 ? weekCost : nil
        guard let result else {
            return make(state: .notSignedIn, message: MistralCopy.notSignedInMessage, reason: .notFound, weekCost: week, now: now)
        }
        switch result {
        case .success(let billing):
            let plan = MistralCopy.planName(billing.planName)
            switch billing.budget {
            case .entries(let entries):
                return make(plan: plan, buckets: MistralBudgetRules.buckets(from: entries), weekCost: week, now: now)
            case .noBilling:
                return make(plan: plan, weekCost: week, now: now)
            case .noUsageAccess:
                return make(plan: plan, state: .error, message: MistralCopy.noUsageAccessMessage, weekCost: week, now: now)
            }
        case .failure(.unauthorized):
            return make(state: .notSignedIn, message: MistralCopy.signedOutMessage, reason: .expired, weekCost: week, now: now)
        case .failure(.rateLimited(let retryAfter)):
            return make(
                state: .error, message: MistralCopy.rateLimitedMessage, retryAfter: retryAfter ?? 60,
                weekCost: week, now: now
            )
        case .failure(.badStatus(let code)):
            return make(
                state: .error, message: HTTPClientError.badStatus(code, body: "").localizedDescription,
                weekCost: week, now: now
            )
        case .failure(.transport(let words)):
            return make(state: .error, message: words, weekCost: week, now: now)
        case .failure(.decoding(let words)):
            return make(
                state: .error, message: HTTPClientError.decoding(words).localizedDescription,
                weekCost: week, now: now
            )
        }
    }

    private nonisolated static func make(
        plan: String? = nil,
        buckets: [UsageBucket] = [],
        state: ServiceState = .ok,
        message: String? = nil,
        reason: SignedOutReason? = nil,
        retryAfter: TimeInterval? = nil,
        weekCost: Double? = nil,
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
            weekCost: weekCost,
            state: state,
            stateMessage: message,
            fetchedAt: now,
            retryAfter: retryAfter,
            signedOutReason: reason
        )
    }
}
