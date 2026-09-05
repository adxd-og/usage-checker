import Foundation

/// Local cost accounting for the Grok CLI, producing the same `CLIBreakdown` that
/// `JSONLAggregator` produces for Claude Code so every dashboard cost view renders
/// unchanged under the Grok tab.
///
/// Sessions live at `~/.grok/sessions/<percent-encoded-cwd>/<session-uuid>/updates.jsonl`,
/// one JSON-RPC notification per line. Only `sessionUpdate == "turn_completed"` carries
/// usage; the streamed chunks and tool calls around it are the other 99% of the bytes
/// (396 MB on a working machine), so every line is byte-scanned for the marker before
/// any JSON parsing happens.
///
/// The CLI logs its own `costUsdTicks` (USD × 1e10) per turn and per model, and that is
/// what we bill: xAI's effective rate moves with cache hits and the 200k context tier,
/// so recomputing it from a price table would drift away from the number `grok` itself
/// shows the user. models.dev pricing is only the fallback for CLI builds that predate
/// the field.
actor GrokUsageAggregator: CostLogAggregating {
    static let shared = GrokUsageAggregator()

    /// `costUsdTicks` is USD × 1e10: 178_020_000 ticks = $0.017802.
    static let ticksPerUSD = 1e10

    /// Stands in for a turn whose payload carries no `modelUsage` split.
    private static let unknownModel = "grok"
    private static let markerBytes = Array("turn_completed".utf8)

    /// One model's slice of one turn.
    private struct ModelSpend: Sendable {
        let model: String
        let cost: Double
        let tokens: Int
    }

    /// One `turn_completed` event: a single user prompt, however many model calls
    /// the agent needed to finish it.
    private struct Turn: Sendable {
        let timestamp: Date
        let projectSlug: String
        let cost: Double
        let tokens: Int
        let models: [ModelSpend]
    }

    private struct DayAgg {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var byFamily: [String: Double] = [:]
    }

    private let rootURL: URL
    /// Byte offset just past the last complete line already parsed, per file. A
    /// partial tail line is deliberately left unconsumed so the next poll re-reads it
    /// whole rather than dropping the turn it belongs to.
    private var fileOffsets: [String: UInt64] = [:]
    /// Turns young enough to feed the rolling today/week/month figures; older ones
    /// fold into `oldDays` and are released (the logs are far too big to keep pinned).
    private var recentTurns: [Turn] = []
    private var oldDays: [Date: DayAgg] = [:]
    private var initialized = false
    private let mtimeWindow: TimeInterval = 90 * 24 * 3600
    /// The rolling figures reach back 30 days; keep turns one day longer so the
    /// month boundary is never clipped.
    private let recentWindow: TimeInterval = 31 * 24 * 3600
    /// Stable hashes of `_meta.eventId`s already counted — a resumed session replays
    /// its earlier lines, and a re-read tail would otherwise double-bill them.
    private var seenEventIDs: Set<UInt64> = []
    private var dayCache: (start: Date, next: Date)?

    /// Injectable log root — the tests point it at a fixture tree instead of the real
    /// `~/.grok/sessions`.
    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".grok/sessions", isDirectory: true)) {
        self.rootURL = rootURL
    }

    func refresh() async {
        // Same runaway backstop as the Claude aggregator: hundreds of days of uptime
        // before it trips, and only replayed sessions could double-count after.
        if seenEventIDs.count > 500_000 {
            seenEventIDs.removeAll()
        }
        scanAndIngest()
        initialized = true
        pruneAndFold()
    }

    /// Just the 7-day total, for the popover's "Last 7 days" row. `breakdown()` builds
    /// the whole daily/project/model matrix; the provider poll needs one number.
    func weekCost(now: Date = Date()) -> Double {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        var total = 0.0
        for t in recentTurns where t.timestamp >= weekAgo { total += t.cost }
        return total
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
            if t.timestamp >= startOfDay {
                todayCost += t.cost
                todayTokens += t.tokens
                todayTurns += 1
                for m in t.models {
                    guard let display = ModelPricing.displayName(for: m.model) else { continue }
                    let p = byModelToday[display] ?? (0, 0)
                    byModelToday[display] = (p.cost + m.cost, p.tokens + m.tokens)
                }
            }
            if t.timestamp >= weekAgo {
                weekCost += t.cost
                var pw = projectsWeekAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pw.cost += t.cost
                pw.tokens += t.tokens
                pw.turns += 1
                pw.lastActivity = max(pw.lastActivity, t.timestamp)
                projectsWeekAcc[t.projectSlug] = pw
            }
            if t.timestamp >= monthAgo {
                monthCost += t.cost
                var pm = projectsMonthAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pm.cost += t.cost
                pm.tokens += t.tokens
                pm.turns += 1
                pm.lastActivity = max(pm.lastActivity, t.timestamp)
                projectsMonthAcc[t.projectSlug] = pm
            }

            let day = dayStart(for: t.timestamp)
            var bucket = dailyAcc[day] ?? DayAgg()
            bucket.cost += t.cost
            bucket.tokens += t.tokens
            bucket.turns += 1
            for m in t.models {
                bucket.byFamily[ModelPricing.family(for: m.model), default: 0] += m.cost
            }
            dailyAcc[day] = bucket
        }

        let daily = dailyAcc.map { (k, v) in
            // Placeholder until task 6 gives DayAgg a breakdown of its own.
            CLIDailySummary(
                day: k, totalCost: v.cost, totalTokens: v.tokens, tokens: .zero,
                turns: v.turns, byFamily: v.byFamily
            )
        }.sorted { $0.day < $1.day }

        let modelsToday = byModelToday
            .map { ($0.key, $0.value.cost, $0.value.tokens, TokenBreakdown.zero) }
            .sorted { $0.1 > $1.1 }

        return CLIBreakdown(
            todayCost: todayCost,
            todayTokens: todayTokens,
            todayTokenBreakdown: .zero,
            todayTurns: todayTurns,
            weekCost: weekCost,
            monthCost: monthCost,
            byModelToday: modelsToday,
            daily: daily,
            projectsWeek: Self.summaries(projectsWeekAcc),
            projectsMonth: Self.summaries(projectsMonthAcc),
            updatedAt: now
        )
    }

    func usage(from start: Date, to end: Date) -> WindowUsage {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var byProject: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var byModel: [String: (cost: Double, tokens: Int)] = [:]

        for t in recentTurns where t.timestamp >= start && t.timestamp <= end {
            cost += t.cost
            tokens += t.tokens
            turns += 1

            var p = byProject[t.projectSlug] ?? (0, 0, 0, t.timestamp)
            p.cost += t.cost
            p.tokens += t.tokens
            p.turns += 1
            p.lastActivity = max(p.lastActivity, t.timestamp)
            byProject[t.projectSlug] = p

            for m in t.models {
                guard let display = ModelPricing.displayName(for: m.model) else { continue }
                let acc = byModel[display] ?? (0, 0)
                byModel[display] = (acc.cost + m.cost, acc.tokens + m.tokens)
            }
        }

        return WindowUsage(
            start: start,
            end: end,
            cost: cost,
            tokens: tokens,
            breakdown: .zero,
            turns: turns,
            projects: Self.summaries(byProject),
            models: byModel
                .map { ($0.key, $0.value.cost, $0.value.tokens, TokenBreakdown.zero) }
                .sorted { $0.1 > $1.1 }
        )
    }

    private static func summaries(
        _ acc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)]
    ) -> [ProjectSummary] {
        acc.map { ProjectSummary(
            slug: $0.key,
            // Grok names its session directory with the percent-encoded absolute cwd,
            // so unlike Claude's dash slug the original path comes back exactly.
            displayName: ProjectName.decode(encodedPath: $0.key),
            totalCost: $0.value.cost,
            totalTokens: $0.value.tokens,
            turns: $0.value.turns,
            lastActivity: $0.value.lastActivity
        ) }
        .sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Ingest

    private func ingest(_ turns: [Turn], eventIDs: [String]) {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        for (turn, eventID) in zip(turns, eventIDs) {
            guard seenEventIDs.insert(Self.stableHash(eventID)).inserted else { continue }
            if turn.timestamp < recentCutoff {
                fold(turn)
            } else {
                recentTurns.append(turn)
            }
        }
    }

    private func fold(_ t: Turn) {
        let day = dayStart(for: t.timestamp)
        var agg = oldDays[day] ?? DayAgg()
        agg.cost += t.cost
        agg.tokens += t.tokens
        agg.turns += 1
        for m in t.models {
            agg.byFamily[ModelPricing.family(for: m.model), default: 0] += m.cost
        }
        oldDays[day] = agg
    }

    private func pruneAndFold() {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        if recentTurns.contains(where: { $0.timestamp < recentCutoff }) {
            var kept: [Turn] = []
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

    /// FNV-1a over UTF-8: stable across launches (unlike `Hasher`), 8 bytes per entry
    /// instead of a retained id string.
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
        var seenPaths = Set<String>()

        for case let url as URL in enumerator {
            guard url.lastPathComponent == "updates.jsonl" else { continue }
            seenPaths.insert(url.path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast

            if firstScan {
                if mtime < cutoff {
                    // Too old to reach any figure we show — skip it forever instead of
                    // parsing it once to throw the result away.
                    fileOffsets[url.path] = UInt64(values?.fileSize ?? 0)
                    continue
                }
                fileOffsets[url.path] = 0
            } else if mtime < cutoff {
                continue
            }

            // One file at a time inside an autorelease pool: a first scan over the
            // whole session tree is hundreds of MB of JSON garbage otherwise.
            autoreleasepool {
                let parsed = parseFile(at: url)
                ingest(parsed.turns, eventIDs: parsed.eventIDs)
            }
        }

        // Offsets for files the enumerator no longer returns — a deleted project, a
        // cleared session — would otherwise be carried for the life of the process.
        if fileOffsets.count > seenPaths.count {
            fileOffsets = fileOffsets.filter { seenPaths.contains($0.key) }
        }
    }

    private func parseFile(at url: URL) -> (turns: [Turn], eventIDs: [String]) {
        let path = url.path
        var start = fileOffsets[path] ?? 0
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return ([], []) }
        // Truncated or rewritten in place — the carried offset points into new content.
        if size < start { start = 0 }
        if size == start { return ([], []) }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], []) }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return ([], []) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], []) }

        // `<root>/<percent-encoded-cwd>/<session-uuid>/updates.jsonl`
        let projectSlug = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var turns: [Turn] = []
        var eventIDs: [String] = []
        var consumedInChunk = 0
        // Marker-first, not line-first: only turn_completed lines carry usage and they
        // are a fraction of a percent of what the CLI writes, so the scan jumps between
        // `memmem` hits and only then finds the line around each one. Walking every byte
        // in Swift instead cost ~24 s on a 400 MB session tree.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            // Everything after the last newline is a half-written tail — leave it for
            // the next poll to re-read whole rather than dropping the turn in it.
            var limit = 0
            var cursor = 0
            while let nl = memchr(base + cursor, 0x0A, raw.count - cursor) {
                cursor = (UnsafeRawPointer(nl) - base) + 1
                limit = cursor
            }
            guard limit > 0 else { return }
            consumedInChunk = limit

            Self.markerBytes.withUnsafeBufferPointer { needle in
                guard let needleBase = needle.baseAddress else { return }
                var searchFrom = 0
                while searchFrom < limit {
                    guard let hit = memmem(base + searchFrom, limit - searchFrom, needleBase, needle.count)
                    else { return }
                    let hitOffset = UnsafeRawPointer(hit) - base
                    // `searchFrom` is always a line start, so the enclosing line begins
                    // at the last newline before the hit.
                    var lineStart = searchFrom
                    while let nl = memchr(base + lineStart, 0x0A, hitOffset - lineStart) {
                        lineStart = (UnsafeRawPointer(nl) - base) + 1
                    }
                    let lineEnd = memchr(base + hitOffset, 0x0A, limit - hitOffset)
                        .map { UnsafeRawPointer($0) - base } ?? limit
                    if lineEnd > lineStart {
                        let line = Data(bytes: base.advanced(by: lineStart), count: lineEnd - lineStart)
                        if let parsed = Self.parseLine(line, projectSlug: projectSlug) {
                            turns.append(parsed.turn)
                            eventIDs.append(parsed.eventID)
                        }
                    }
                    searchFrom = lineEnd + 1
                }
            }
        }
        fileOffsets[path] = start + UInt64(consumedInChunk)
        return (turns, eventIDs)
    }

    // MARK: - Line parsing

    /// One model's raw counters, before the CLI's cost figure is reconciled.
    private struct RawModelUsage {
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreate: Int
        let tokens: Int
        /// The CLI's own figure, when this build of the CLI logs one.
        var cost: Double?

        /// models.dev's answer, for CLI builds that predate `costUsdTicks`. Zero when
        /// no price is known — a turn we can't price still has to contribute its
        /// tokens and its place in the day rather than vanishing.
        var pricedCost: Double {
            guard let p = ModelPricing.dynamicLookup(for: model) else { return 0 }
            let fresh = max(0, input - cacheRead)
            return (Double(fresh) * p.inputPerM
                + Double(output) * p.outputPerM
                + Double(cacheRead) * p.cacheReadPerM
                + Double(cacheCreate) * p.cacheCreate5mPerM) / 1_000_000.0
        }
    }

    private static func parseLine(_ data: Data, projectSlug: String) -> (turn: Turn, eventID: String)? {
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = any["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              (update["sessionUpdate"] as? String) == "turn_completed",
              let usage = update["usage"] as? [String: Any]
        else { return nil }

        let meta = params["_meta"] as? [String: Any]
        // `timestamp` is unix seconds; `_meta.agentTimestampMs` is the same instant
        // in milliseconds and is the fallback when the outer field is missing.
        guard let seconds = doubleValue(any["timestamp"])
                ?? doubleValue(meta?["agentTimestampMs"]).map({ $0 / 1000 })
        else { return nil }
        let timestamp = Date(timeIntervalSince1970: seconds)

        // eventId is unique per logged event and stable across a session resume.
        let eventID = (meta?["eventId"] as? String)
            ?? "\(params["sessionId"] as? String ?? projectSlug)|\(Int(seconds))|\(intValue(usage["totalTokens"]))"

        var rows: [RawModelUsage] = []
        if let modelUsage = usage["modelUsage"] as? [String: Any] {
            for (model, value) in modelUsage {
                guard let entry = value as? [String: Any] else { continue }
                rows.append(rawUsage(model: model, from: entry))
            }
        }
        if rows.isEmpty {
            rows = [rawUsage(model: unknownModel, from: usage)]
        }

        let turnCost = ticksToUSD(usage["costUsdTicks"])
        let spends = resolveCosts(rows, turnCost: turnCost)
        let turn = Turn(
            timestamp: timestamp,
            projectSlug: projectSlug,
            cost: spends.reduce(0) { $0 + $1.cost },
            tokens: spends.reduce(0) { $0 + $1.tokens },
            models: spends
        )
        return (turn, eventID)
    }

    private static func rawUsage(model: String, from usage: [String: Any]) -> RawModelUsage {
        // Counters are clamped at zero: a negative token count is nonsense that would
        // subtract from the day's total and skew the per-model share the turn cost is
        // split by.
        let input = max(0, intValue(usage["inputTokens"]))
        let output = max(0, intValue(usage["outputTokens"]))
        // `totalTokens` is input + output, and `cachedReadTokens` is a subset of
        // `inputTokens` — adding the cache fields on top would double-count them.
        let total = max(0, intValue(usage["totalTokens"]))
        return RawModelUsage(
            model: model,
            input: input,
            output: output,
            cacheRead: max(0, intValue(usage["cachedReadTokens"])),
            cacheCreate: max(0, intValue(usage["cacheCreationTokens"])),
            tokens: total > 0 ? total : input + output,
            cost: ticksToUSD(usage["costUsdTicks"])
        )
    }

    /// `costUsdTicks` as dollars, or nil when the field doesn't actually price anything.
    ///
    /// Zero and negative tick counts are "unpriced", not "free": a `costUsdTicks: 0`
    /// used to read as a real $0, which marked the row priced and skipped the models.dev
    /// fallback entirely — so a CLI build that writes the field but leaves it empty
    /// silently reported a whole session as costing nothing.
    private static func ticksToUSD(_ any: Any?) -> Double? {
        guard let ticks = doubleValue(any), ticks > 0 else { return nil }
        return ticks / ticksPerUSD
    }

    /// Ten ticks ($1e-9). The per-row figures and the turn total are separate sums of
    /// the same doubles, so a "remainder" smaller than this is rounding, not money.
    private static let remainderEpsilon = 10 / ticksPerUSD

    /// The CLI's per-model ticks are the answer whenever it logs them. Rows it didn't
    /// price fall back to the turn's own total (split by token share), and then to
    /// models.dev rates.
    ///
    /// When every row IS priced but the turn total is larger, the difference is real
    /// spend the per-model split doesn't account for — a model the CLI billed without
    /// breaking out. It used to be discarded, so the turn read cheaper than the CLI's
    /// own figure. It goes onto the biggest row rather than onto a synthetic "unknown"
    /// one, which would surface in the dashboard's per-model breakdown as a model the
    /// user never ran.
    private static func resolveCosts(_ rows: [RawModelUsage], turnCost: Double?) -> [ModelSpend] {
        let unpriced = rows.filter { $0.cost == nil }
        let alreadyPriced = rows.reduce(0.0) { $0 + ($1.cost ?? 0) }

        guard !unpriced.isEmpty else {
            var spends = rows.map { ModelSpend(model: $0.model, cost: $0.cost ?? 0, tokens: $0.tokens) }
            guard let turnCost, turnCost - alreadyPriced > remainderEpsilon,
                  let biggest = spends.indices.max(by: { spends[$0].cost < spends[$1].cost })
            else { return spends }
            spends[biggest] = ModelSpend(
                model: spends[biggest].model,
                cost: spends[biggest].cost + (turnCost - alreadyPriced),
                tokens: spends[biggest].tokens
            )
            return spends
        }

        if let turnCost, turnCost > alreadyPriced {
            let remainder = turnCost - alreadyPriced
            let unpricedTokens = unpriced.reduce(0) { $0 + $1.tokens }
            return rows.map { row in
                guard row.cost == nil else {
                    return ModelSpend(model: row.model, cost: row.cost ?? 0, tokens: row.tokens)
                }
                let share = unpricedTokens > 0
                    ? Double(row.tokens) / Double(unpricedTokens)
                    : 1.0 / Double(unpriced.count)
                return ModelSpend(model: row.model, cost: remainder * share, tokens: row.tokens)
            }
        }
        return rows.map { ModelSpend(model: $0.model, cost: $0.cost ?? $0.pricedCost, tokens: $0.tokens) }
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
