import Foundation

/// Local cost accounting for the Codex CLI, producing the same `CLIBreakdown` that
/// `JSONLAggregator` produces for Claude Code and `GrokUsageAggregator` for Grok, so
/// every dashboard cost view renders unchanged under the Codex tab.
///
/// Sessions live at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, one JSON object per
/// line. `event_msg` / `payload.type == "token_count"` carries a **cumulative**
/// `info.total_token_usage` counter, so each event's delta against the previous reading
/// is one turn, attributed to the model named by the preceding `turn_context`.
/// `session_meta` is always line 1 and `turn_context` always precedes the first
/// `token_count` (verified across the whole rollout tree, 2026-09-05).
///
/// Codex's `input_tokens` *includes* cached input, so fresh input is `input − cached`;
/// `reasoning_output_tokens` is a subset of `output_tokens` and never joins the total.
/// OpenAI doesn't bill cache writes — the count is still shown.
actor CodexUsageAggregator: CostLogAggregating {
    static let shared = CodexUsageAggregator()

    /// One `token_count` delta: what the model call added to the session.
    private struct Turn: Sendable {
        let timestamp: Date
        let model: String
        let projectSlug: String
        let cost: Double
        let tokens: TokenBreakdown
    }

    /// One cumulative `total_token_usage` reading, and (as a difference of two) one
    /// turn's raw counters.
    private struct Counters {
        var input = 0
        var cached = 0
        var cacheWrite = 0
        var output = 0
        var reasoning = 0
    }

    /// Per-file incremental parse state. The cumulative-counter format means a resumed
    /// parse must carry the previous baseline, the selected model and the project the
    /// `session_meta` line named, so the active session file only has its new tail read
    /// on each poll instead of being re-materialized whole.
    private struct FileState {
        /// Byte offset just past the last fully parsed line; a partial tail line is
        /// re-read on the next poll.
        var consumed: UInt64 = 0
        var currentModel: String?
        /// The `session_meta` cwd, percent-encoded — see `encode(cwd:)`.
        var projectSlug: String?
        /// Cumulative counters as of the previous `token_count` event.
        var prev = Counters()
    }

    private let rootURL: URL
    private var fileStates: [String: FileState] = [:]
    /// Turns young enough to feed the rolling today/week/month figures; older ones fold
    /// into `oldDays` and are released.
    private var recentTurns: [Turn] = []
    private var oldDays: [Date: DayAgg] = [:]
    private let mtimeWindow: TimeInterval = 90 * 24 * 3600
    /// The rolling figures reach back 30 days; keep turns one day longer so the month
    /// boundary is never clipped.
    private let recentWindow: TimeInterval = 31 * 24 * 3600
    private var dayCache: (start: Date, next: Date)?

    private struct DayAgg {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var byFamily: [String: Double] = [:]
        var breakdown = TokenBreakdown.zero
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Injectable log root — the tests point it at a fixture tree instead of the real
    /// `~/.codex/sessions`.
    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.rootURL = rootURL
    }

    func refresh() async {
        ingestAll()
    }

    /// Week / today dollars for the menu-bar popover and `CodexProvider`, which ask for
    /// them without going through `refresh()`.
    func costs(now: Date = Date()) -> (week: Double, today: Double) {
        ingestAll()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        var week = 0.0
        var today = 0.0
        // The week reaches back 7 days and `recentWindow` is 31, so the folded days can
        // never hold a turn either figure needs.
        for t in recentTurns {
            if t.timestamp >= weekAgo { week += t.cost }
            if t.timestamp >= startOfDay { today += t.cost }
        }
        return (week, today)
    }

    func breakdown() -> CLIBreakdown {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        var todayCost = 0.0
        var todayTokens = 0
        var todayTurns = 0
        var todayBreakdown = TokenBreakdown.zero
        var weekCost = 0.0
        var monthCost = 0.0
        var byModelToday: [String: (cost: Double, tokens: Int, breakdown: TokenBreakdown)] = [:]
        var dailyAcc = oldDays
        var projectsWeekAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var projectsMonthAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]

        for t in recentTurns {
            if t.timestamp >= startOfDay {
                todayCost += t.cost
                todayTokens += t.tokens.total
                todayTurns += 1
                todayBreakdown += t.tokens
                if let display = ModelPricing.displayName(for: t.model) {
                    var m = byModelToday[display] ?? (0, 0, .zero)
                    m.cost += t.cost
                    m.tokens += t.tokens.total
                    m.breakdown += t.tokens
                    byModelToday[display] = m
                }
            }
            if t.timestamp >= weekAgo {
                weekCost += t.cost
                var pw = projectsWeekAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pw.cost += t.cost
                pw.tokens += t.tokens.total
                pw.turns += 1
                pw.lastActivity = max(pw.lastActivity, t.timestamp)
                projectsWeekAcc[t.projectSlug] = pw
            }
            if t.timestamp >= monthAgo {
                monthCost += t.cost
                var pm = projectsMonthAcc[t.projectSlug] ?? (0, 0, 0, t.timestamp)
                pm.cost += t.cost
                pm.tokens += t.tokens.total
                pm.turns += 1
                pm.lastActivity = max(pm.lastActivity, t.timestamp)
                projectsMonthAcc[t.projectSlug] = pm
            }

            let day = dayStart(for: t.timestamp)
            var bucket = dailyAcc[day] ?? DayAgg()
            bucket.cost += t.cost
            bucket.tokens += t.tokens.total
            bucket.turns += 1
            bucket.breakdown += t.tokens
            bucket.byFamily[ModelPricing.family(for: t.model), default: 0] += t.cost
            dailyAcc[day] = bucket
        }

        let daily = dailyAcc.map { (k, v) in
            CLIDailySummary(
                day: k, totalCost: v.cost, totalTokens: v.tokens, tokens: v.breakdown,
                turns: v.turns, byFamily: v.byFamily
            )
        }.sorted { $0.day < $1.day }

        let modelsToday = byModelToday
            .map { ($0.key, $0.value.cost, $0.value.tokens, $0.value.breakdown) }
            .sorted { $0.1 > $1.1 }

        return CLIBreakdown(
            todayCost: todayCost,
            todayTokens: todayTokens,
            todayTokenBreakdown: todayBreakdown,
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
        // Not `breakdown`: a local of that name would shadow the `breakdown()` method,
        // for the same reason the other two aggregators spell it out here.
        var windowBreakdown = TokenBreakdown.zero
        var byProject: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var byModel: [String: (cost: Double, tokens: Int, breakdown: TokenBreakdown)] = [:]

        for t in recentTurns where t.timestamp >= start && t.timestamp <= end {
            cost += t.cost
            tokens += t.tokens.total
            turns += 1
            windowBreakdown += t.tokens

            var p = byProject[t.projectSlug] ?? (0, 0, 0, t.timestamp)
            p.cost += t.cost
            p.tokens += t.tokens.total
            p.turns += 1
            p.lastActivity = max(p.lastActivity, t.timestamp)
            byProject[t.projectSlug] = p

            if let display = ModelPricing.displayName(for: t.model) {
                var m = byModel[display] ?? (0, 0, .zero)
                m.cost += t.cost
                m.tokens += t.tokens.total
                m.breakdown += t.tokens
                byModel[display] = m
            }
        }

        return WindowUsage(
            start: start,
            end: end,
            cost: cost,
            tokens: tokens,
            breakdown: windowBreakdown,
            turns: turns,
            projects: Self.summaries(byProject),
            models: byModel
                .map { ($0.key, $0.value.cost, $0.value.tokens, $0.value.breakdown) }
                .sorted { $0.1 > $1.1 }
        )
    }

    private static func summaries(
        _ acc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)]
    ) -> [ProjectSummary] {
        acc.map { ProjectSummary(
            slug: $0.key,
            // The slug is the session's percent-encoded cwd, exactly like Grok's
            // session-directory names, so the original path comes back losslessly.
            displayName: ProjectName.decode(encodedPath: $0.key),
            totalCost: $0.value.cost,
            totalTokens: $0.value.tokens,
            turns: $0.value.turns,
            lastActivity: $0.value.lastActivity
        ) }
        .sorted { $0.totalCost > $1.totalCost }
    }

    // MARK: - Ingest

    private func ingestAll() {
        scanAndIngest()
        pruneAndFold()
    }

    private func ingest(_ turns: [Turn]) {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        for turn in turns {
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
        agg.tokens += t.tokens.total
        agg.turns += 1
        agg.breakdown += t.tokens
        agg.byFamily[ModelPricing.family(for: t.model), default: 0] += t.cost
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

    // MARK: - File scanning

    private func scanAndIngest() {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-mtimeWindow)
        var seenPaths: Set<String> = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Untouched for 90 days: too old to reach any figure we show, so it is never
            // parsed and — by staying out of `seenPaths` — never remembered either.
            guard (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            seenPaths.insert(url.path)

            var state = fileStates[url.path] ?? FileState()
            if size < state.consumed {
                // Truncated or rewritten in place — the carried baseline is invalid.
                state = FileState()
            }
            if size > state.consumed {
                // One file at a time inside an autorelease pool: a first scan over a
                // long-lived session tree is a lot of JSON garbage otherwise.
                autoreleasepool { parseTail(at: url, state: &state) }
            }
            fileStates[url.path] = state
        }
        // A file that aged out of the mtime window, or was deleted, never hits the loop
        // again — without eviction its parse state stays pinned for the life of the
        // process.
        if fileStates.count > seenPaths.count {
            fileStates = fileStates.filter { seenPaths.contains($0.key) }
        }
    }

    private func parseTail(at url: URL, state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.consumed) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Last resort for a rollout that names no cwd anywhere.
        let fallbackSlug = url.deletingPathExtension().lastPathComponent
        var turns: [Turn] = []
        var consumedInChunk = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            var cursor = 0
            // Everything after the last newline is a half-written tail — leave it for
            // the next poll to re-read whole rather than dropping the event in it.
            while let nl = memchr(base + cursor, 0x0A, raw.count - cursor) {
                let i = UnsafeRawPointer(nl) - base
                if i > lineStart {
                    let line = Data(bytes: base.advanced(by: lineStart), count: i - lineStart)
                    if let turn = parseLine(line, state: &state, fallbackSlug: fallbackSlug) {
                        turns.append(turn)
                    }
                }
                lineStart = i + 1
                cursor = lineStart
            }
            consumedInChunk = lineStart
        }
        state.consumed += UInt64(consumedInChunk)
        ingest(turns)
    }

    // MARK: - Line parsing

    /// Folds `session_meta` / `turn_context` into the carried parse state and returns
    /// the turn a `token_count` delta completes, if any.
    private func parseLine(_ data: Data, state: inout FileState, fallbackSlug: String) -> Turn? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        if type == "session_meta" {
            if let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String {
                state.projectSlug = Self.encode(cwd: cwd)
            }
            return nil
        }

        if type == "turn_context" {
            if let payload = obj["payload"] as? [String: Any] {
                if let model = payload["model"] as? String { state.currentModel = model }
                // `session_meta` names the cwd on line 1 of every rollout; this is the
                // fallback for a file whose first line we never saw.
                if state.projectSlug == nil, let cwd = payload["cwd"] as? String {
                    state.projectSlug = Self.encode(cwd: cwd)
                }
            }
            return nil
        }

        // `token_usage_record` restates the same counters under its own type; billing it
        // would double every figure.
        guard type == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any]
        else { return nil }

        let reading = Counters(
            input: Self.intValue(total["input_tokens"]),
            cached: Self.intValue(total["cached_input_tokens"]),
            cacheWrite: Self.intValue(total["cache_write_input_tokens"]),
            output: Self.intValue(total["output_tokens"]),
            reasoning: Self.intValue(total["reasoning_output_tokens"])
        )
        let previous = state.prev
        state.prev = reading

        var delta = Counters(
            input: reading.input - previous.input,
            cached: reading.cached - previous.cached,
            cacheWrite: reading.cacheWrite - previous.cacheWrite,
            output: reading.output - previous.output,
            reasoning: reading.reasoning - previous.reasoning
        )
        // Compaction or a fresh thread restarts the cumulative counter — the reading is
        // then the delta.
        if delta.input < 0 || delta.output < 0 { delta = reading }
        guard delta.input > 0 || delta.output > 0 else { return nil }

        // Every rollout writes `turn_context` before its first `token_count`, so this is
        // a malformed file rather than an unpriced model (which is kept, below).
        guard let model = state.currentModel else { return nil }

        let cacheRead = max(0, delta.cached)
        var tokens = TokenBreakdown(
            input: max(0, delta.input - cacheRead),
            output: max(0, delta.output),
            cacheRead: cacheRead,
            cacheWrite5m: max(0, delta.cacheWrite),
            cacheWrite1h: 0,
            thinking: max(0, delta.reasoning)
        )
        // models.dev prices Codex models; a model it doesn't know keeps its tokens
        // with no dollar split (`cost` stays nil).
        if let price = ModelPricing.dynamicLookup(for: model) {
            tokens = tokens.priced(with: price)
        }

        let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()
        return Turn(
            timestamp: ts,
            model: model,
            projectSlug: state.projectSlug ?? fallbackSlug,
            // `cost` is nil for a model models.dev doesn't know.
            // $0 is the honest answer for the dollar column; dropping the turn and its
            // tokens with it would not be.
            cost: tokens.cost?.total ?? 0,
            tokens: tokens
        )
    }

    /// The session's cwd, percent-encoded the way the Grok CLI names its session
    /// directories, so `ProjectName.decode(encodedPath:)` renders both providers'
    /// project rows alike.
    private static func encode(cwd: String) -> String {
        cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cwd
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
