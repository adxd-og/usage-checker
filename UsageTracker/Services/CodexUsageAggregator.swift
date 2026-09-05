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

    /// Per-file incremental parse state. The cumulative-counter format means a
    /// resumed parse must carry the previous baseline and selected model, so the
    /// active session file only has its new tail read on each poll instead of
    /// being re-materialized whole.
    private struct FileState {
        /// Byte offset just past the last fully parsed line; a partial tail line
        /// is re-read on the next poll.
        var consumed: UInt64 = 0
        var spends: [Spend] = []
        var currentModel: String?
        /// Cumulative counters as of the previous token_count event.
        var prev: (input: Int, cached: Int, output: Int) = (0, 0, 0)
    }

    private var fileCache: [String: FileState] = [:]

    private let rootURL: URL

    /// Injectable log root — the tests point it at a fixture tree instead of the real
    /// `~/.codex/sessions`.
    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.rootURL = rootURL
    }

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
        var seenPaths: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            seenPaths.insert(url.path)

            var state = fileCache[url.path] ?? FileState()
            if size < state.consumed {
                // Truncated or rewritten in place — the carried baseline is invalid.
                state = FileState()
            }
            if size > state.consumed {
                parseTail(at: url, state: &state)
            }
            fileCache[url.path] = state
            all.append(contentsOf: state.spends)
        }
        // Files that aged out of the mtime window never hit the loop again — without
        // eviction their parsed spends stay pinned for the life of the process.
        for path in fileCache.keys where !seenPaths.contains(path) {
            fileCache.removeValue(forKey: path)
        }
        return all
    }

    private func parseTail(at url: URL, state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.consumed) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        var consumedInChunk = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            for i in 0..<raw.count {
                if raw.load(fromByteOffset: i, as: UInt8.self) == 0x0A {
                    if i > lineStart {
                        let line = Data(bytes: base.advanced(by: lineStart), count: i - lineStart)
                        parseLine(line, into: &state)
                    }
                    lineStart = i + 1
                }
            }
            consumedInChunk = lineStart
        }
        state.consumed += UInt64(consumedInChunk)
    }

    private func parseLine(_ data: Data, into state: inout FileState) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "turn_context" {
            if let payload = obj["payload"] as? [String: Any], let model = payload["model"] as? String {
                state.currentModel = model
            }
            return
        }

        guard type == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any]
        else { return }

        let input = intValue(total["input_tokens"])
        let cached = intValue(total["cached_input_tokens"])
        let output = intValue(total["output_tokens"])

        // Compaction or a fresh thread can reset the counter — restart the baseline.
        var delta = (input: input - state.prev.input, cached: cached - state.prev.cached, output: output - state.prev.output)
        if delta.input < 0 || delta.output < 0 {
            delta = (input, cached, output)
        }
        state.prev = (input, cached, output)
        guard delta.input > 0 || delta.output > 0 else { return }

        guard let model = state.currentModel,
              let price = ModelPricing.dynamicLookup(for: model) else {
            // Unknown model or pricing not loaded yet — better to skip than to guess.
            return
        }
        let freshInput = max(0, delta.input - delta.cached)
        let cost = (Double(freshInput) * price.inputPerM
            + Double(max(0, delta.cached)) * price.cacheReadPerM
            + Double(delta.output) * price.outputPerM) / 1_000_000.0

        let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()
        state.spends.append(Spend(timestamp: ts, cost: cost))
    }

    private func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
