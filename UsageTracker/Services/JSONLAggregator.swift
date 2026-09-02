import Foundation

struct CLITurn: Sendable, Codable {
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

    /// What one transcript looked like the last time we read it. `offset` stops just
    /// past the last complete line: a partial tail is deliberately left unconsumed so
    /// the next poll re-reads it whole rather than dropping the turn it belongs to.
    /// `size` and `mtime` are the skip key — a file that still looks exactly like this
    /// holds nothing we haven't already counted, so it is never opened again.
    private struct FileMark: Codable, Equatable {
        var offset: UInt64
        var size: UInt64
        /// Always whole seconds (`markTime`), so it survives the cache's ISO-8601 round
        /// trip byte-identical. Without that, every mark restored from disk would
        /// mismatch the file's nanosecond-precision mtime and the cache would buy
        /// nothing at all. The blind spot — an in-place edit that lands in the same
        /// second and leaves the length untouched — cannot happen to an append-only log.
        var mtime: Date
    }

    /// A day of spend that has already been folded out of `recentTurns`, in a shape
    /// `oldDays` can be rebuilt from.
    private struct DayEntry: Codable {
        let day: Date
        let cost: Double
        let tokens: Int
        let turns: Int
        let byFamily: [String: Double]
    }

    /// Everything a relaunch needs to answer "what did I spend?" without re-reading
    /// gigabytes of transcripts. Rejected wholesale if it was written by another
    /// version or for another log root.
    private struct CostCacheSnapshot: Codable {
        let version: Int
        let root: String
        let savedAt: Date
        let fileMarks: [String: FileMark]
        let recentTurns: [CLITurn]
        let oldDays: [DayEntry]
        let seenMessageIDs: [UInt64]
    }

    private static let cacheVersion = 1

    private let rootURL: URL
    /// Where the cache is kept; nil disables it entirely (the tests that don't care).
    private let cacheURL: URL?
    /// Per file, what we already consumed and what the file looked like when we did.
    private var fileMarks: [String: FileMark] = [:]
    /// Turns young enough to feed the rolling today/week/month figures. Turns
    /// that age past `recentWindow` are folded into `oldDays` and released —
    /// holding every turn of the 90-day window pinned tens of MB permanently.
    private var recentTurns: [CLITurn] = []
    /// Day-level aggregates for turns older than `recentWindow` — all `daily` needs.
    private var oldDays: [Date: DayAgg] = [:]
    private var initialized = false
    private let isoFormatter: ISO8601DateFormatter
    /// Same format without the fractional-seconds requirement. Real Claude Code logs
    /// always carry fractions, but a writer that stops doing so must not silently cost
    /// us every turn's timestamp.
    private let isoFormatterNoFraction: ISO8601DateFormatter
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
    /// How many transcripts the last scan actually opened. Zero is the normal answer
    /// for a poll with nothing new, and for a relaunch off a warm cache.
    private(set) var filesParsedInLastScan = 0
    /// Set whenever this refresh changed something worth persisting. A quiet poll
    /// leaves it false and the cache file untouched.
    private var dirty = false
    /// The snapshot runs to tens of MB on a busy machine, so a poll that ingests one
    /// turn must not rewrite the whole file. Writes are batched to this interval; the
    /// first one in the process is immediate, so a crash early on still leaves
    /// something warm behind, and `flushCache()` ignores the throttle at quit.
    private let saveInterval: TimeInterval
    private var lastSavedAt: Date?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Not private: it is the default argument of an internal initializer, and a
    /// default argument may not reference a private member.
    static var defaultCacheURL: URL {
        AgentPaths.appSupportURL.appendingPathComponent("cost-cache-claude-v1.json")
    }

    /// Injectable log root and cache location — the tests point both at a temp
    /// directory instead of the real `~/.claude/projects` and Application Support.
    /// A nil `cacheURL` turns persistence off.
    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        cacheURL: URL? = JSONLAggregator.defaultCacheURL,
        saveInterval: TimeInterval = 300
    ) {
        self.rootURL = rootURL
        self.cacheURL = cacheURL
        self.saveInterval = saveInterval
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.isoFormatterNoFraction = plain
    }

    func refresh() async {
        loadCache()
        // Runaway backstop: ~250 days of continuous uptime before this trips;
        // after a clear, only forked-session replays could double-count.
        if seenMessageIDs.count > 500_000 {
            seenMessageIDs.removeAll()
            dirty = true
        }
        scanAndIngest()
        initialized = true
        pruneAndFold()
        saveIfDue()
    }

    /// Writes the cache now, throttle and all, if anything is waiting to be written.
    /// The app calls this on the way out so a session's last few minutes of turns
    /// survive the quit instead of being re-parsed on the next launch.
    func flushCache() {
        guard dirty else { return }
        save()
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
            dirty = true
        }
        let dayCutoff = dayStart(for: Date().addingTimeInterval(-mtimeWindow))
        if oldDays.keys.contains(where: { $0 < dayCutoff }) {
            oldDays = oldDays.filter { $0.key >= dayCutoff }
            dirty = true
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
        filesParsedInLastScan = 0
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-mtimeWindow)
        var seenPaths = Set<String>()

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path
            seenPaths.insert(path)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Epoch rather than `.distantPast` for a file whose attributes won't read:
            // both are far outside the window, but only one survives the cache round trip.
            let mtime = Self.markTime(values?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
            let size = UInt64(values?.fileSize ?? 0)

            let start: UInt64
            if let mark = fileMarks[path] {
                // Byte-for-byte what we already read — not opened, on this poll or any
                // relaunch after it. This is the whole point of the cache: 2.3 GB of
                // transcripts costs one `stat` each instead of a full parse.
                if size == mark.size, mtime == mark.mtime { continue }
                // Shorter than what we already consumed: the file was rewritten, so
                // read it from the top. The `seenMessageIDs` dedupe makes the replay free.
                start = size < mark.offset ? 0 : mark.offset
            } else {
                // Nothing written here for the whole 90-day window is outside every
                // figure we report; record it consumed rather than reading it.
                if mtime < cutoff {
                    fileMarks[path] = FileMark(offset: size, size: size, mtime: mtime)
                    dirty = true
                    continue
                }
                start = 0
            }

            // Same length, newer timestamp — a touch, or a rewrite of identical bytes.
            // Move the mark on so the next poll can skip it, but don't open anything.
            if size == start {
                fileMarks[path] = FileMark(offset: start, size: size, mtime: mtime)
                dirty = true
                continue
            }

            filesParsedInLastScan += 1
            // One file at a time, drained inside an autorelease pool: the first
            // scan used to buffer every turn from ~1 GB of logs (plus all the
            // JSONSerialization garbage) before deduping, spiking memory past 1 GB.
            autoreleasepool {
                ingest(parseFile(at: url, from: start, size: size, mtime: mtime))
            }
        }

        // Marks for files the enumerator no longer returns — a deleted project, a
        // cleared session — would otherwise be carried for the life of the process,
        // and now for the life of the cache file too.
        if fileMarks.count > seenPaths.count {
            fileMarks = fileMarks.filter { seenPaths.contains($0.key) }
            dirty = true
        }
    }

    /// `size` and `mtime` are what the file looked like *before* the read: a write that
    /// lands while we parse must leave the mark stale, so the next poll comes back for it.
    private func parseFile(at url: URL, from start: UInt64, size: UInt64, mtime: Date) -> [CLITurn] {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd() else { return [] }

        // Claude Code stores sessions under ~/.claude/projects/<project-slug>/<session-uuid>.jsonl
        // The project slug is the parent directory name (an encoded absolute path).
        let projectSlug = url.deletingLastPathComponent().lastPathComponent
        var turns: [CLITurn] = []
        var consumedInChunk = 0
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
                    consumedInChunk = lineStart
                }
            }
        }
        // Only past the last newline, never to `size`. A poll can land between the
        // write of a line's bytes and its terminator, and marking the whole file
        // consumed skipped that half-written line AND guaranteed it would never be
        // read again — the turn was lost for good. Leaving the offset short makes the
        // next poll re-read the line whole. Unchanged when the chunk holds no newline
        // at all, which is the same situation stretched over more than one poll.
        fileMarks[path] = FileMark(offset: start + UInt64(consumedInChunk), size: size, mtime: mtime)
        dirty = true
        return turns
    }

    // MARK: - The on-disk cache

    /// Whole seconds — see `FileMark.mtime`.
    private static func markTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Restores the last run's state, once, before the first scan. Any problem at all —
    /// no file, unreadable, written by another build or for another log root — just
    /// leaves the aggregator cold, which costs time and never correctness.
    private func loadCache() {
        guard !initialized, let cacheURL else { return }
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let snapshot: CostCacheSnapshot
        do {
            snapshot = try decoder.decode(CostCacheSnapshot.self, from: data)
        } catch {
            NSLog("[UT] cost cache unreadable, rebuilding from the logs")
            return
        }
        guard snapshot.version == Self.cacheVersion, snapshot.root == rootURL.path else {
            NSLog("[UT] cost cache is for another version or log root, ignoring")
            return
        }
        fileMarks = snapshot.fileMarks
        recentTurns = snapshot.recentTurns
        // Last one wins rather than merged: a day repeated in a hand-edited file is
        // corruption, and counting it twice would be worse than dropping half of it.
        var days: [Date: DayAgg] = [:]
        for entry in snapshot.oldDays {
            days[entry.day] = DayAgg(
                cost: entry.cost, tokens: entry.tokens, turns: entry.turns, byFamily: entry.byFamily
            )
        }
        oldDays = days
        seenMessageIDs = Set(snapshot.seenMessageIDs)
        NSLog(
            "[UT] cost cache restored: %ld files, %ld recent turns",
            fileMarks.count, recentTurns.count
        )
    }

    /// Nothing to write, or written too recently to be worth the tens of MB again.
    private func saveIfDue() {
        guard dirty else { return }
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < saveInterval { return }
        save()
    }

    /// The timestamp moves even when the write fails, so a cache we can't write —
    /// a full disk, a revoked sandbox — is retried on the same interval rather than
    /// on every poll.
    private func save() {
        lastSavedAt = Date()
        if saveCache() { dirty = false }
    }

    @discardableResult
    private func saveCache() -> Bool {
        guard let cacheURL else { return true }
        let snapshot = CostCacheSnapshot(
            version: Self.cacheVersion,
            root: rootURL.path,
            savedAt: Date(),
            fileMarks: fileMarks,
            recentTurns: recentTurns,
            oldDays: oldDays.map {
                DayEntry(day: $0.key, cost: $0.value.cost, tokens: $0.value.tokens,
                         turns: $0.value.turns, byFamily: $0.value.byFamily)
            },
            seenMessageIDs: Array(seenMessageIDs)
        )
        do {
            let data = try encoder.encode(snapshot)
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: [.atomic])
            return true
        } catch {
            NSLog("[UT] cost cache write failed: %@", String(describing: error))
            return false
        }
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
        // A line we can't date must be dropped, not billed as "now": the old
        // `?? Date()` put a turn from an unparseable line into today's spend and into
        // whatever rate window happens to be open, which is the one place a wrong
        // answer is worse than no answer. Fractions first (what Claude Code writes),
        // then plain ISO8601 for a writer that stops emitting them.
        guard let ts = isoFormatter.date(from: tsStr) ?? isoFormatterNoFraction.date(from: tsStr)
        else { return nil }
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
