import Foundation

/// Local cost accounting for the Codex CLI, mirroring what `JSONLAggregator` does for
/// Claude Code. Sessions live in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`;
/// `token_count` events carry a **cumulative** `total_token_usage` counter, so each
/// event's delta is attributed to the model currently selected by the preceding
/// `turn_context` line. Cached input is included in `input_tokens` and billed at the
/// cache-read rate; OpenAI doesn't bill cache writes.
actor CodexUsageAggregator {
    static let shared = CodexUsageAggregator()

    struct Spend: Sendable {
        let timestamp: Date
        let cost: Double
    }

    /// Sessions older than this can't contribute to the 7-day figure.
    private let mtimeWindow: TimeInterval = 8 * 24 * 3600
    /// Per-file parse cache: unchanged files aren't re-read on every poll.
    private var fileCache: [String: (size: UInt64, spends: [Spend])] = [:]

    private let rootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func costs(now: Date = Date()) -> (week: Double, today: Double) {
        let spends = collectSpends()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        var week = 0.0
        var today = 0.0
        for s in spends {
            if s.timestamp >= weekAgo { week += s.cost }
            if s.timestamp >= startOfDay { today += s.cost }
        }
        return (week, today)
    }

    private func collectSpends() -> [Spend] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-mtimeWindow)
        var all: [Spend] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let size = UInt64(values?.fileSize ?? 0)

            if let cached = fileCache[url.path], cached.size == size {
                all.append(contentsOf: cached.spends)
                continue
            }
            let spends = parseFile(at: url)
            fileCache[url.path] = (size, spends)
            all.append(contentsOf: spends)
        }
        return all
    }

    private func parseFile(at url: URL) -> [Spend] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var spends: [Spend] = []
        var currentModel: String?
        // Cumulative counters as of the previous token_count event.
        var prev = (input: 0, cached: 0, output: 0)

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            if type == "turn_context" {
                if let payload = obj["payload"] as? [String: Any], let model = payload["model"] as? String {
                    currentModel = model
                }
                continue
            }

            guard type == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any]
            else { continue }

            let input = intValue(total["input_tokens"])
            let cached = intValue(total["cached_input_tokens"])
            let output = intValue(total["output_tokens"])

            // Compaction or a fresh thread can reset the counter — restart the baseline.
            var delta = (input: input - prev.input, cached: cached - prev.cached, output: output - prev.output)
            if delta.input < 0 || delta.output < 0 {
                delta = (input, cached, output)
            }
            prev = (input, cached, output)
            guard delta.input > 0 || delta.output > 0 else { continue }

            guard let model = currentModel,
                  let price = ModelPricing.dynamicLookup(for: model) else {
                // Unknown model or pricing not loaded yet — better to skip than to guess.
                continue
            }
            let freshInput = max(0, delta.input - delta.cached)
            let cost = (Double(freshInput) * price.inputPerM
                + Double(max(0, delta.cached)) * price.cacheReadPerM
                + Double(delta.output) * price.outputPerM) / 1_000_000.0

            let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()
            spends.append(Spend(timestamp: ts, cost: cost))
        }
        return spends
    }

    private func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
