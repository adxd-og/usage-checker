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
    /// anthropic prices the Claude CLI accounting; openai prices the Codex CLI accounting.
    private static let providers = ["anthropic", "openai"]

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
        // v2: anthropic + openai. The name bump forces a refetch over a v1
        // (anthropic-only) cache that could otherwise linger for a day.
        return dir.appendingPathComponent("models-dev-pricing-v2.json")
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

        var prices: [String: ModelPrice] = [:]
        for provider in providers {
            guard let providerDict = root[provider] as? [String: Any],
                  let models = providerDict["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"])
                else { continue }
                let cacheRead = doubleValue(cost["cache_read"]) ?? input * 0.1
                // models.dev reports the 5-minute cache-write rate. Anthropic always
                // sends one (and prices the 1-hour tier at a stable 1.6× of it); a
                // provider without cache_write (OpenAI) doesn't bill cache writes.
                let cacheWrite5m = doubleValue(cost["cache_write"])
                    ?? (provider == "anthropic" ? input * 1.25 : 0)
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
