import Foundation

/// Keeps `ModelPricing` fresh from models.dev — the public model-pricing dataset
/// (the same source CodexBar uses) — so a newly launched Claude model gets correct
/// $ rates without anyone editing the hardcoded table.
///
/// The hardcoded `ModelPricing.table` stays as the offline fallback: this loader
/// only layers a dynamic table on top when the fetch/cache succeeds. When the next
/// check may run is `ModelsDevRefresher`'s business.
///
/// The same answer carries models.dev's `mistral` family, which prices the vibe CLI's
/// sessions from a table of its own (`vibeFamily`, `MistralModelPricing`).
enum ModelsDevPricing {
    private static let apiURL = URL(string: "https://models.dev/api.json")!
    /// How long a fetched table is good for, and how long a good check waits.
    static let maxCacheAge: TimeInterval = 24 * 3600
    /// How long a failed fetch waits before the next try. A day was too long when
    /// nothing else could price a turn: a first launch offline, with no copy on disk,
    /// left every Codex turn at $0 until the next day's check.
    static let retryAfterFailure: TimeInterval = 15 * 60
    /// anthropic prices the Claude CLI accounting, openai the Codex CLI's, xai the Grok
    /// CLI's fallback path (the CLI normally logs its own dollars), google the Gemini /
    /// Antigravity model ids that turn up in shared logs. One table for all four, filled
    /// family by family: on an id two of them share, the last family's rate wins.
    static let providers = ["anthropic", "openai", "xai", "google"]

    /// The family the vibe CLI's sessions are priced from (spec 2026-11-10 Mistral provider
    /// § Local usage (P2), Model and price), read into a table of its own with each model's
    /// display name (`MistralModelPricing`). Not one of `providers`: Mistral resells models
    /// other families list, and in the shared table a shared id would take one family's rate
    /// for every CLI.
    static let vibeFamily = "mistral"

    /// One models.dev answer: the four families' rates for the other CLIs, and the Mistral
    /// family, rates and names, for vibe's.
    struct Table: Equatable, Sendable {
        let prices: [String: ModelPrice]
        let mistral: [String: MistralModelPricing.Model]
    }

    /// The copy on disk: when it was fetched, and what it said.
    struct Cache: Codable {
        let fetchedAt: Date
        let prices: [String: ModelPrice]
        /// The Mistral family, rates and names. Optional, so a copy written without it (a
        /// test that scripts the four families alone) still opens.
        var mistral: [String: MistralModelPricing.Model]? = nil
    }

    /// v4 adds the Mistral family and its names (v3 added xai + google). Each name bump
    /// forces a refetch over the previous cache, which would otherwise linger a full day
    /// missing what the new version reads.
    static let cacheFileName = "models-dev-pricing-v4.json"

    /// Not private: the default argument of `ModelsDevRefresher.init`.
    static var defaultCacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("UsageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFileName)
    }

    /// What one check came to.
    enum Outcome: Equatable, Sendable {
        /// The copy on disk was younger than `maxCacheAge`; nothing was fetched.
        case freshCache
        /// models.dev answered, and its table is live.
        case fetched
        /// The fetch failed; whatever was there before — a stale disk copy, or only the
        /// offline table — stays.
        case failed
    }

    /// When the check after this one may run, decided from the answer rather than
    /// stamped before the question: a good answer waits `maxCacheAge`, a failed fetch
    /// only `retryAfterFailure`.
    static func nextAttempt(after outcome: Outcome, at now: Date) -> Date {
        switch outcome {
        case .freshCache, .fetched: return now.addingTimeInterval(maxCacheAge)
        case .failed: return now.addingTimeInterval(retryAfterFailure)
        }
    }

    /// Called on every poll; cheap no-op unless the next check is due. The first call
    /// also seeds `ModelPricing` from the disk copy, so prices are correct even before
    /// (or without) a network round-trip.
    static func refreshIfStale() async {
        await ModelsDevRefresher.shared.refreshIfStale()
    }

    /// Not private: the default fetch of `ModelsDevRefresher.init`. It carries no credential,
    /// so it stays on `URLSession.shared` (whose cache `NetworkCachePolicy` empties).
    static func fetchLive() async throws -> Table {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return try table(root)
    }

    /// Both tables out of one answer. Throws when the four families price nothing, as `parse`.
    static func table(_ root: [String: Any]) throws -> Table {
        Table(prices: try parse(root), mistral: parseFamily(root, provider: vibeFamily))
    }

    /// Split out of `fetchLive` so the shape handling is testable against a fixture with no
    /// network round-trip. Only the base rates are read: `tiers` and `context_over_200k`
    /// describe the long-context surcharge, and neither CLI log says which tier a turn
    /// billed at, so applying them would be a guess.
    static func parse(_ root: [String: Any]) throws -> [String: ModelPrice] {
        var prices: [String: ModelPrice] = [:]
        for provider in providers {
            guard let providerDict = root[provider] as? [String: Any],
                  let models = providerDict["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                // Image and video models carry `"cost": null` — no rate to record, and
                // the cast has to tolerate NSNull rather than assume a dictionary.
                guard let model = value as? [String: Any],
                      let rate = Self.price(provider: provider, id: id, model: model)
                else { continue }
                prices[ModelPricing.normalize(id)] = rate
            }
        }
        guard !prices.isEmpty else { throw URLError(.cannotParseResponse) }
        return prices
    }

    /// One family's models by normalised id, each with its base rates as `parse` reads them (nil
    /// when models.dev gives none) and its display name. Empty when the answer has no such family.
    static func parseFamily(_ root: [String: Any], provider: String) -> [String: MistralModelPricing.Model] {
        guard let providerDict = root[provider] as? [String: Any],
              let models = providerDict["models"] as? [String: Any] else { return [:] }
        var family: [String: MistralModelPricing.Model] = [:]
        for (id, value) in models {
            guard let model = value as? [String: Any] else { continue }
            family[ModelPricing.normalize(id)] = MistralModelPricing.Model(
                price: Self.price(provider: provider, id: id, model: model),
                name: model["name"] as? String
            )
        }
        return family
    }

    /// One model's base rates: input and output as published, cache reads at a tenth of input
    /// when models.dev publishes none, cache writes as published or as `inferredCacheWrite5m`
    /// says, the 1-hour tier a stable 1.6× of the 5-minute one. nil when `cost` is missing, not
    /// an object, or lacks input or output.
    static func price(provider: String, id: String, model: [String: Any]) -> ModelPrice? {
        guard let cost = model["cost"] as? [String: Any],
              let input = doubleValue(cost["input"]),
              let output = doubleValue(cost["output"])
        else { return nil }
        let cacheRead = doubleValue(cost["cache_read"]) ?? input * 0.1
        // models.dev reports the 5-minute cache-write rate; the 1-hour tier is a
        // stable 1.6× of it. A published rate always wins over the inference.
        let cacheWrite5m = doubleValue(cost["cache_write"])
            ?? inferredCacheWrite5m(provider: provider, modelID: id, inputPerM: input)
        return ModelPrice(
            inputPerM: input,
            outputPerM: output,
            cacheReadPerM: cacheRead,
            cacheCreate5mPerM: cacheWrite5m,
            cacheCreate1hPerM: cacheWrite5m * 1.6
        )
    }

    /// The 5-minute cache-write rate to assume for a model models.dev publishes none for.
    ///
    /// Anthropic bills every cache write, at 1.25× the input rate. OpenAI began billing
    /// them with GPT-5.6 — the same 1.25× multiple on the uncached input rate, alongside
    /// 0.1× for cached reads — and bills nothing for the lines before it. xAI, Google and
    /// Mistral bill no cache writes at all.
    static func inferredCacheWrite5m(provider: String, modelID: String, inputPerM: Double) -> Double {
        switch provider {
        case "anthropic": return inputPerM * 1.25
        case "openai": return billsCacheWrites(openAIModelID: modelID) ? inputPerM * 1.25 : 0
        default: return 0
        }
    }

    /// GPT-5.6 and GPT-6 bill cache writes; every OpenAI line before them does not.
    /// A prefix test rather than a version comparison, because these ids are the only
    /// two shapes that matter — models.dev already publishes a `cache_write` for most
    /// of them, and a rate it publishes wins over this either way.
    static func billsCacheWrites(openAIModelID: String) -> Bool {
        let id = ModelPricing.normalize(openAIModelID)
        return id.hasPrefix("gpt-5.6") || id.hasPrefix("gpt-6")
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    static func readCache(at url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    static func writeCache(_ cache: Cache, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

/// The models.dev check and its schedule. One shared instance serves the app's poll;
/// a test makes its own, with a temp cache file and a scripted fetch.
///
/// The next check is scheduled once the answer is in (`ModelsDevPricing.nextAttempt`),
/// so a failed fetch is tried again within the quarter hour instead of the next day.
/// While a fetch is out, a second call returns at once: the poll can come round before
/// a slow fetch has answered, and asking twice would buy nothing.
actor ModelsDevRefresher {
    static let shared = ModelsDevRefresher()

    private let cacheURL: URL
    private let fetch: @Sendable () async throws -> ModelsDevPricing.Table
    private var nextAttemptAt: Date = .distantPast
    private var inFlight = false

    init(
        cacheURL: URL = ModelsDevPricing.defaultCacheURL,
        fetchTable: @escaping @Sendable () async throws -> ModelsDevPricing.Table = {
            try await ModelsDevPricing.fetchLive()
        }
    ) {
        self.cacheURL = cacheURL
        self.fetch = fetchTable
    }

    /// For a test that scripts the four families' prices alone: the Mistral family comes back
    /// empty.
    init(cacheURL: URL, fetch: @escaping @Sendable () async throws -> [String: ModelPrice]) {
        self.init(cacheURL: cacheURL, fetchTable: {
            ModelsDevPricing.Table(prices: try await fetch(), mistral: [:])
        })
    }

    func refreshIfStale(now: Date = Date()) async {
        guard !inFlight, now >= nextAttemptAt else { return }
        inFlight = true
        let outcome = await check(now: now)
        nextAttemptAt = ModelsDevPricing.nextAttempt(after: outcome, at: now)
        inFlight = false
    }

    private func check(now: Date) async -> ModelsDevPricing.Outcome {
        if let cache = ModelsDevPricing.readCache(at: cacheURL) {
            ModelPricing.updateDynamic(cache.prices)
            MistralModelPricing.update(cache.mistral ?? [:])
            if now.timeIntervalSince(cache.fetchedAt) < ModelsDevPricing.maxCacheAge {
                NSLog("[UT] models.dev pricing: %d models from cache", cache.prices.count)
                return .freshCache
            }
        }
        do {
            let table = try await fetch()
            ModelPricing.updateDynamic(table.prices)
            MistralModelPricing.update(table.mistral)
            ModelsDevPricing.writeCache(
                ModelsDevPricing.Cache(fetchedAt: now, prices: table.prices, mistral: table.mistral), to: cacheURL
            )
            NSLog("[UT] models.dev pricing: %d models fetched, %d Mistral", table.prices.count, table.mistral.count)
            return .fetched
        } catch {
            // Keep whatever we had (disk copy or the hardcoded table); try again soon.
            NSLog("[UT] models.dev pricing fetch failed: %@", String(describing: error))
            return .failed
        }
    }
}
