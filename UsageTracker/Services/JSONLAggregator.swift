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

/// What ran inside one rate-limit window — the answer to "why is my session at 90%?".
///
/// Cost is a proxy, not a decomposition: the JSONL knows dollars, the rate limit counts
/// in units Anthropic doesn't publish. So this ranks what you were *doing* while the
/// window filled, which is the actionable half of the question.
struct WindowUsage: Sendable {
    let start: Date
    let end: Date
    let cost: Double
    let tokens: Int
    let turns: Int
    /// Ranked by cost, descending.
    let projects: [ProjectSummary]
    let models: [(model: String, cost: Double, tokens: Int)]

    var isEmpty: Bool { turns == 0 }
}

/// A local per-turn cost log the dashboard can chart. Cost is a local-log question,
/// not an API one — a provider is costable exactly when its CLI writes token/dollar
/// figures to disk. Claude Code and the Grok CLI both do, and speak the same shapes
/// here so every cost view works for either without knowing which is selected.
protocol CostLogAggregating: Actor {
    /// Incrementally ingest whatever the CLI has written since the last call.
    func refresh() async
    func breakdown() async -> CLIBreakdown
    func usage(from start: Date, to end: Date) async -> WindowUsage
}

actor JSONLAggregator: CostLogAggregating {
    static let shared = JSONLAggregator()

    private struct DayAgg {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var byFamily: [String: Double] = [:]
    }

    private let rootURL: URL
    private var fileOffsets: [String: UInt64] = [:]
    /// Turns young enough to feed the rolling today/week/month figures. Turns
    /// that age past `recentWindow` are folded into `oldDays` and released —
    /// holding every turn of the 90-day window pinned tens of MB permanently.
    private var recentTurns: [CLITurn] = []
    /// Day-level aggregates for turns older than `recentWindow` — all `daily` needs.
    private var oldDays: [Date: DayAgg] = [:]
    private var initialized = false
    private let isoFormatter: ISO8601DateFormatter
    private let mtimeWindow: TimeInterval = 90 * 24 * 3600
    /// The rolling figures reach back 30 days; keep turns one day longer so the
    /// month boundary is never clipped.
    private let recentWindow: TimeInterval = 31 * 24 * 3600
    /// Stable 64-bit hashes of message ids already counted, so duplicate log lines
    /// (re-scanned tails, forked sessions replaying old messages) never inflate cost.
    private var seenMessageIDs: Set<UInt64> = []
    /// One cached day interval covers the common case: log lines arrive in
    /// near-chronological runs, and `Calendar.startOfDay` is far too expensive
    /// to call per turn.
    private var dayCache: (start: Date, next: Date)?

    /// Injectable log root — the tests point it at a fixture directory instead of
    /// the real `~/.claude/projects`.
    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.rootURL = rootURL
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
    }

    func refresh() async {
        // Runaway backstop: ~250 days of continuous uptime before this trips;
        // after a clear, only forked-session replays could double-count.
        if seenMessageIDs.count > 500_000 {
            seenMessageIDs.removeAll()
        }
        scanAndIngest()
        initialized = true
        pruneAndFold()
    }

    func breakdown() -> CLIBreakdown {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        var todayCost = 0.0
        var todayTokens = 0
        var todayTurns = 0
        var weekCost = 0.0
        var monthCost = 0.0
        var byModelToday: [String: (cost: Double, tokens: Int)] = [:]
        var dailyAcc = oldDays
        var projectsWeekAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var projectsMonthAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]

        for t in recentTurns {
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

            let day = dayStart(for: t.timestamp)
            var bucket = dailyAcc[day] ?? DayAgg()
            bucket.cost += c
            bucket.tokens += tokens
            bucket.turns += 1
            bucket.byFamily[ModelPricing.family(for: t.model), default: 0] += c
            dailyAcc[day] = bucket
        }

        let daily = dailyAcc.map { (k, v) in
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

    /// Slices the already-parsed turns to one window. Cheap: `recentTurns` holds a
    /// month, and a rate-limit window is hours.
    func usage(from start: Date, to end: Date) -> WindowUsage {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var byProject: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var byModel: [String: (cost: Double, tokens: Int)] = [:]

        for t in recentTurns where t.timestamp >= start && t.timestamp <= end {
            let c = t.cost
            let tok = t.totalTokens
            cost += c
            tokens += tok
            turns += 1

            var p = byProject[t.projectSlug] ?? (0, 0, 0, t.timestamp)
            p.cost += c
            p.tokens += tok
            p.turns += 1
            p.lastActivity = max(p.lastActivity, t.timestamp)
            byProject[t.projectSlug] = p

            if let modelDisplay = ModelPricing.displayName(for: t.model) {
                let m = byModel[modelDisplay] ?? (0, 0)
                byModel[modelDisplay] = (m.cost + c, m.tokens + tok)
            }
        }

        return WindowUsage(
            start: start,
            end: end,
            cost: cost,
            tokens: tokens,
            turns: turns,
            projects: byProject
                .map { ProjectSummary(
                    slug: $0.key,
                    displayName: ProjectName.decode(slug: $0.key),
                    totalCost: $0.value.cost,
                    totalTokens: $0.value.tokens,
                    turns: $0.value.turns,
                    lastActivity: $0.value.lastActivity
                ) }
                .sorted { $0.totalCost > $1.totalCost },
            models: byModel
                .map { ($0.key, $0.value.cost, $0.value.tokens) }
                .sorted { $0.1 > $1.1 }
        )
    }

    // MARK: - Ingest

    private func ingest(_ turns: [CLITurn]) {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        for turn in turns {
            // Each API response is logged multiple times with the same message id; count it once.
            guard seenMessageIDs.insert(Self.stableHash(turn.id)).inserted else { continue }
            // Synthetic / internal Claude Code events aren't user-facing models.
            if ModelPricing.isSynthetic(turn.model) { continue }
            if turn.timestamp < recentCutoff {
                fold(turn)
            } else {
                recentTurns.append(turn)
            }
        }
    }

    private func fold(_ t: CLITurn) {
        let day = dayStart(for: t.timestamp)
        var agg = oldDays[day] ?? DayAgg()
        agg.cost += t.cost
        agg.tokens += t.totalTokens
        agg.turns += 1
        agg.byFamily[ModelPricing.family(for: t.model), default: 0] += t.cost
        oldDays[day] = agg
    }

    private func pruneAndFold() {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        if recentTurns.contains(where: { $0.timestamp < recentCutoff }) {
            var kept: [CLITurn] = []
            kept.reserveCapacity(recentTurns.count)
            for t in recentTurns {
                if t.timestamp < recentCutoff { fold(t) } else { kept.append(t) }
            }
            recentTurns = kept
        }
        let dayCutoff = dayStart(for: Date().addingTimeInterval(-mtimeWindow))
        if oldDays.keys.contains(where: { $0 < dayCutoff }) {
            oldDays = oldDays.filter { $0.key >= dayCutoff }
        }
    }

    private func dayStart(for date: Date) -> Date {
        if let c = dayCache, date >= c.start, date < c.next { return c.start }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let next = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        dayCache = (start, next)
        return start
    }

    /// FNV-1a over UTF-8: stable across launches (unlike `Hasher`), 8 bytes per
    /// entry instead of a retained id string.
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    // MARK: - File scanning

    private func scanAndIngest() {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let firstScan = !initialized
        let cutoff = Date().addingTimeInterval(-mtimeWindow)

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

            // One file at a time, drained inside an autorelease pool: the first
            // scan used to buffer every turn from ~1 GB of logs (plus all the
            // JSONSerialization garbage) before deduping, spiking memory past 1 GB.
            autoreleasepool {
                ingest(parseFile(at: url))
            }
        }
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
