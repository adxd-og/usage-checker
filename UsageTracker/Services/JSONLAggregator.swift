import Foundation

struct CLITurn: Sendable {
    /// The API message id (`msg_…`). Stable across the 3–4 duplicate log lines Claude
    /// Code writes for one response, so it's the dedup key.
    let id: String
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreate5mTokens: Int
    let cacheCreate1hTokens: Int
    let projectSlug: String

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreate5mTokens + cacheCreate1hTokens
    }

    var cost: Double {
        let p = ModelPricing.price(for: model)
        return (Double(inputTokens) * p.inputPerM
              + Double(outputTokens) * p.outputPerM
              + Double(cacheReadTokens) * p.cacheReadPerM
              + Double(cacheCreate5mTokens) * p.cacheCreate5mPerM
              + Double(cacheCreate1hTokens) * p.cacheCreate1hPerM) / 1_000_000.0
    }
}

struct CLIDailySummary: Sendable, Identifiable {
    let day: Date
    let totalCost: Double
    let totalTokens: Int
    let turns: Int
    let byFamily: [String: Double] // opus / sonnet / haiku → $

    var id: Date { day }
}

struct ProjectSummary: Sendable, Identifiable {
    let slug: String
    let displayName: String
    let totalCost: Double
    let totalTokens: Int
    let turns: Int
    let lastActivity: Date
    var id: String { slug }
}

struct CLIBreakdown: Sendable {
    let todayCost: Double
    let todayTokens: Int
    let todayTurns: Int
    let weekCost: Double
    let monthCost: Double
    let byModelToday: [(model: String, cost: Double, tokens: Int)]
    let daily: [CLIDailySummary]
    let projectsWeek: [ProjectSummary]
    let projectsMonth: [ProjectSummary]
    let updatedAt: Date
}

actor JSONLAggregator {
    static let shared = JSONLAggregator()

    private let rootURL: URL
    private var fileOffsets: [String: UInt64] = [:]
    private var allTurns: [CLITurn] = []
    private var initialized = false
    private let isoFormatter: ISO8601DateFormatter
    private let mtimeWindow: TimeInterval = 90 * 24 * 3600
    /// Message ids already counted, so duplicate log lines (and re-scanned file tails)
    /// never inflate cost.
    private var seenMessageIDs: Set<String> = []

    private init() {
        self.rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
    }

    func refresh() async {
        let newRaw = scanIncrementally()
        guard !newRaw.isEmpty || !initialized else { initialized = true; return }
        // Each API response is logged multiple times with the same message id; count it once.
        for turn in newRaw where seenMessageIDs.insert(turn.id).inserted {
            allTurns.append(turn)
        }
        if allTurns.count > 200_000 {
            allTurns.removeFirst(allTurns.count - 150_000)
            seenMessageIDs = Set(allTurns.map(\.id))
        }
        initialized = true
    }

    func breakdown() -> CLIBreakdown {
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        var todayCost = 0.0
        var todayTokens = 0
        var todayTurns = 0
        var weekCost = 0.0
        var monthCost = 0.0
        var byModelToday: [String: (cost: Double, tokens: Int)] = [:]
        var dailyCost: [Date: (cost: Double, tokens: Int, turns: Int, byFamily: [String: Double])] = [:]
        var projectsWeekAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var projectsMonthAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]

        for t in allTurns {
            // Skip synthetic / internal Claude Code events — they're not user-facing models.
            if ModelPricing.isSynthetic(t.model) { continue }
            let c = t.cost
            let tokens = t.totalTokens
            if t.timestamp >= startOfDay {
                todayCost += c
                todayTokens += tokens
                todayTurns += 1
                if let modelDisplay = ModelPricing.displayName(for: t.model) {
                    let p = byModelToday[modelDisplay] ?? (0, 0)
                    byModelToday[modelDisplay] = (p.cost + c, p.tokens + tokens)
                }
            }
            if t.timestamp >= weekAgo {
                weekCost += c
                var pw = projectsWeekAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pw.cost += c
                pw.tokens += tokens
                pw.turns += 1
                pw.lastActivity = max(pw.lastActivity, t.timestamp)
                projectsWeekAcc[t.projectSlug] = pw
            }
            if t.timestamp >= monthAgo {
                monthCost += c
                var pm = projectsMonthAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pm.cost += c
                pm.tokens += tokens
                pm.turns += 1
                pm.lastActivity = max(pm.lastActivity, t.timestamp)
                projectsMonthAcc[t.projectSlug] = pm
            }

            let day = cal.startOfDay(for: t.timestamp)
            var bucket = dailyCost[day] ?? (0, 0, 0, [:])
            bucket.cost += c
            bucket.tokens += tokens
            bucket.turns += 1
            let family = ModelPricing.family(for: t.model)
            bucket.byFamily[family, default: 0] += c
            dailyCost[day] = bucket
        }

        let daily = dailyCost.map { (k, v) in
            CLIDailySummary(day: k, totalCost: v.cost, totalTokens: v.tokens, turns: v.turns, byFamily: v.byFamily)
        }.sorted { $0.day < $1.day }

        let modelsToday = byModelToday
            .map { ($0.key, $0.value.cost, $0.value.tokens) }
            .sorted { $0.1 > $1.1 }

        let projectsWeek = projectsWeekAcc
            .map { ProjectSummary(
                slug: $0.key,
                displayName: ProjectName.decode(slug: $0.key),
                totalCost: $0.value.cost,
                totalTokens: $0.value.tokens,
                turns: $0.value.turns,
                lastActivity: $0.value.lastActivity
            ) }
            .sorted { $0.totalCost > $1.totalCost }

        let projectsMonth = projectsMonthAcc
            .map { ProjectSummary(
                slug: $0.key,
                displayName: ProjectName.decode(slug: $0.key),
                totalCost: $0.value.cost,
                totalTokens: $0.value.tokens,
                turns: $0.value.turns,
                lastActivity: $0.value.lastActivity
            ) }
            .sorted { $0.totalCost > $1.totalCost }

        return CLIBreakdown(
            todayCost: todayCost,
            todayTokens: todayTokens,
            todayTurns: todayTurns,
            weekCost: weekCost,
            monthCost: monthCost,
            byModelToday: modelsToday,
            daily: daily,
            projectsWeek: projectsWeek,
            projectsMonth: projectsMonth,
            updatedAt: now
        )
    }

    // MARK: - File scanning

    private func scanIncrementally() -> [CLITurn] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let firstScan = !initialized
        let cutoff = Date().addingTimeInterval(-mtimeWindow)
        var output: [CLITurn] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast

            if firstScan {
                let size = UInt64(values?.fileSize ?? 0)
                if mtime < cutoff {
                    fileOffsets[url.path] = size
                    continue
                }
                fileOffsets[url.path] = 0
            } else if mtime < cutoff {
                continue
            }

            output.append(contentsOf: parseFile(at: url))
        }
        return output
    }

    private func parseFile(at url: URL) -> [CLITurn] {
        let path = url.path
        var start = fileOffsets[path] ?? 0
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return [] }
        if size < start { start = 0 }
        if size == start { return [] }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd() else { return [] }
        fileOffsets[path] = size

        // Claude Code stores sessions under ~/.claude/projects/<project-slug>/<session-uuid>.jsonl
        // The project slug is the parent directory name (an encoded absolute path).
        let projectSlug = url.deletingLastPathComponent().lastPathComponent
        var turns: [CLITurn] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            for i in 0..<raw.count {
                if raw.load(fromByteOffset: i, as: UInt8.self) == 0x0A {
                    if i > lineStart {
                        let line = Data(bytes: base.advanced(by: lineStart), count: i - lineStart)
                        if let t = parseLine(line, projectSlug: projectSlug) {
                            turns.append(t)
                        }
                    }
                    lineStart = i + 1
                }
            }
        }
        return turns
    }

    private func parseLine(_ data: Data, projectSlug: String) -> CLITurn? {
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let type = any["type"] as? String, type == "assistant" else { return nil }
        guard let message = any["message"] as? [String: Any] else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        let msgID = (message["id"] as? String) ?? ""
        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        var c5: Int = 0
        var c1h: Int = 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            c5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
            c1h = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
        }

        let tsStr = (any["timestamp"] as? String) ?? ""
        let ts = isoFormatter.date(from: tsStr) ?? Date()
        // Older logs may lack a message id — fall back to a content identity so exact
        // duplicate lines still dedupe.
        let id = msgID.isEmpty
            ? "\(tsStr)|\(model)|\(input)|\(output)|\(cacheRead)|\(c5)|\(c1h)"
            : msgID

        return CLITurn(
            id: id,
            timestamp: ts,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreate5mTokens: c5,
            cacheCreate1hTokens: c1h,
            projectSlug: projectSlug
        )
    }
}
