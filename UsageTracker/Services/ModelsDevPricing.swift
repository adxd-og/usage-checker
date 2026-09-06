import Foundation

/// Keeps `ModelPricing` fresh from models.dev — the public model-pricing dataset
/// (the same source CodexBar uses) — so a newly launched Claude model gets correct
/// $ rates without anyone editing the hardcoded table.
///
/// The hardcoded `ModelPricing.table` stays as the offline fallback: this loader
/// only layers a dynamic table on top when the fetch/cache succeeds.
enum ModelsDevPricing {
    private static let apiURL = URL(string: "https://models.dev/api.json")!
    private static let maxCacheAge: TimeInterval = 24 * 3600
    /// anthropic prices the Claude CLI accounting, openai the Codex CLI's, xai the Grok
    /// CLI's fallback path (the CLI normally logs its own dollars), google the Gemini /
    /// Antigravity model ids that turn up in shared logs.
    static let providers = ["anthropic", "openai", "xai", "google"]

    /// In-memory guard so the periodic poll only re-checks once per day.
    nonisolated(unsafe) private static var lastAttemptAt: Date = .distantPast
    private static let attemptLock = NSLock()

    private struct Cache: Codable {
        let fetchedAt: Date
        let prices: [String: ModelPrice]
    }

    private static var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("UsageTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // v3: adds xai + google. Each name bump forces a refetch over the previous
        // cache, which would otherwise linger a full day missing the new providers.
        return dir.appendingPathComponent("models-dev-pricing-v3.json")
    }

    /// Called on every poll; cheap no-op unless a day has passed since the last check.
    /// On first call it also seeds `ModelPricing` from the disk cache, so prices are
    /// correct even before (or without) a network round-trip.
    static func refreshIfStale() async {
        let now = Date()
        let shouldAttempt: Bool = {
            attemptLock.lock()
            defer { attemptLock.unlock() }
            guard now.timeIntervalSince(lastAttemptAt) >= maxCacheAge else { return false }
            lastAttemptAt = now
            return true
        }()
        guard shouldAttempt else { return }

        if let cache = readCache() {
            ModelPricing.updateDynamic(cache.prices)
            if now.timeIntervalSince(cache.fetchedAt) < maxCacheAge {
                NSLog("[UT] models.dev pricing: %d models from cache", cache.prices.count)
                return
            }
        }

        do {
            let prices = try await fetch()
            ModelPricing.updateDynamic(prices)
            writeCache(Cache(fetchedAt: now, prices: prices))
            NSLog("[UT] models.dev pricing: %d models fetched", prices.count)
        } catch {
            // Keep whatever we had (disk cache or the hardcoded table); retry tomorrow.
            NSLog("[UT] models.dev pricing fetch failed: %@", String(describing: error))
        }
    }

    private static func fetch() async throws -> [String: ModelPrice] {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return try parse(root)
    }

    /// Split out of `fetch` so the shape handling is testable against a fixture with no
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
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"])
                else { continue }
                let cacheRead = doubleValue(cost["cache_read"]) ?? input * 0.1
                // models.dev reports the 5-minute cache-write rate; the 1-hour tier is a
                // stable 1.6× of it. A published rate always wins over the inference.
                let cacheWrite5m = doubleValue(cost["cache_write"])
                    ?? inferredCacheWrite5m(provider: provider, modelID: id, inputPerM: input)
                prices[ModelPricing.normalize(id)] = ModelPrice(
                    inputPerM: input,
                    outputPerM: output,
                    cacheReadPerM: cacheRead,
                    cacheCreate5mPerM: cacheWrite5m,
                    cacheCreate1hPerM: cacheWrite5m * 1.6
                )
            }
        }
        guard !prices.isEmpty else { throw URLError(.cannotParseResponse) }
        return prices
    }

    /// The 5-minute cache-write rate to assume for a model models.dev publishes none for.
    ///
    /// Anthropic bills every cache write, at 1.25× the input rate. OpenAI began billing
    /// them with GPT-5.6 — the same 1.25× multiple on the uncached input rate, alongside
    /// 0.1× for cached reads — and bills nothing for the lines before it. xAI and Google
    /// bill no cache writes at all.
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

    private static func readCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    private static func writeCache(_ cache: Cache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }
}
