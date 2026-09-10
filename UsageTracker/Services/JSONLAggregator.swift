import Foundation

struct CLITurn: Sendable, Codable {
    /// The API message id (`msg_…`). Stable across the 3–4 duplicate log lines Claude
    /// Code writes for one response, so it's the dedup key.
    let id: String
    let timestamp: Date
    let model: String
    /// The turn's tokens split by kind, already priced: every turn this aggregator
    /// parses carries a per-category dollar split.
    let tokens: TokenBreakdown
    let projectSlug: String
    /// The chat this turn belongs to: Claude Code's `sessionId`, the same value on the
    /// main transcript and on every sub-agent transcript that chat spawned. `""` for a
    /// log line old enough not to carry one — such a turn still counts towards the day
    /// and window figures, it just belongs to no chat.
    var sessionID: String = ""
    /// `agentId` when the record is a sub-agent's, nil on the main thread.
    var agentID: String? = nil
    /// `attributionAgent`: the agent's type (`general-purpose`, `executor`, `planner`, …).
    var agentKind: String? = nil
    /// `effort` as the record carries it (`high`, `xhigh`, …).
    var effort: String? = nil

    // The five counters the rest of the app still reads by name.
    var inputTokens: Int { tokens.input }
    var outputTokens: Int { tokens.output }
    var cacheReadTokens: Int { tokens.cacheRead }
    var cacheCreate5mTokens: Int { tokens.cacheWrite5m }
    var cacheCreate1hTokens: Int { tokens.cacheWrite1h }

    var totalTokens: Int { tokens.total }

    /// The dollars priced with the turn, which is what the per-category split shows.
    ///
    /// Recomputing here instead — as this used to — made the headline and the split
    /// disagree the moment a rate moved under a turn already ingested: the split was
    /// priced once at parse time, the headline on every read. The stored figure keeps
    /// the two describing the same turn the same way. The table is still the answer for
    /// a turn that carries no split at all.
    var cost: Double {
        if let stored = tokens.cost { return stored.total }
        let p = ModelPricing.price(for: model)
        return (Double(inputTokens) * p.inputPerM
              + Double(outputTokens) * p.outputPerM
              + Double(cacheReadTokens) * p.cacheReadPerM
              + Double(cacheCreate5mTokens) * p.cacheCreate5mPerM
              + Double(cacheCreate1hTokens) * p.cacheCreate1hPerM) / 1_000_000.0
    }
}

extension CLITurn {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, model, tokens, projectSlug
        case sessionID, agentID, agentKind, effort
    }

    /// Hand-written so the four fields default rather than throw when they are absent.
    /// The cache version bump discards every snapshot written before them anyway; this
    /// is so a snapshot that reaches the decoder some other way reports "an older
    /// shape" by producing a turn without a chat, not "unreadable".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            model: try c.decode(String.self, forKey: .model),
            tokens: try c.decode(TokenBreakdown.self, forKey: .tokens),
            projectSlug: try c.decode(String.self, forKey: .projectSlug),
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
            agentID: try c.decodeIfPresent(String.self, forKey: .agentID),
            agentKind: try c.decodeIfPresent(String.self, forKey: .agentKind),
            effort: try c.decodeIfPresent(String.self, forKey: .effort)
        )
    }
}

/// What one transcript line says. Claude Code's log is not only turns — the chat's
/// name and the user's first prompt live in it too — and one JSON parse per line has
/// to answer for all three.
enum ParsedRecord {
    case turn(CLITurn)
    /// `{"type":"ai-title","aiTitle":…,"sessionId":…}`. A chat carries many; the last wins.
    case title(sessionID: String, title: String)
    /// The first human prompt of a chat, already collapsed and cut.
    case prompt(sessionID: String, text: String)
}

/// One `String` instance per distinct value in a transcript.
///
/// A session id is 36 bytes — past the 15 Swift keeps inline — so without this every
/// turn held in `recentTurns` pins its own copy of an id it shares with thousands of
/// others: several megabytes across a month of turns for a handful of distinct chats.
struct StringPool {
    private var pool: [String: String] = [:]
    /// A transcript holds a handful of distinct ids; the cap only guards a corrupt file.
    private let limit = 512

    mutating func intern(_ s: String) -> String {
        if let hit = pool[s] { return hit }
        if pool.count < limit { pool[s] = s }
        return s
    }
}

/// The chat's name, as the two records that can carry one leave it.
enum SessionTitle {
    /// Eighty characters, ellipsis included: about what a row of the session list has
    /// room for, and a prompt is often a whole pasted paragraph.
    static let limit = 80

    /// `ai-title`'s own string. Collapsed and cut like a prompt, so a name nobody
    /// bounded cannot push a row off the screen.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return collapse(raw)
    }

    /// The first human prompt as a name. `message.content` is a plain string in every
    /// transcript on this Mac and `[{"type":"text","text":…}]` in the shape the logs
    /// also allow; anything else has no text to show.
    static func firstPrompt(from content: Any?) -> String? {
        if let text = content as? String { return collapse(text) }
        if let parts = content as? [[String: Any]] {
            let text = parts
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
            return collapse(text)
        }
        return nil
    }

    /// Every run of whitespace — the newlines a pasted prompt is full of included —
    /// becomes one space, and the result is cut to `limit` characters with an ellipsis
    /// as the last one. nil when there is nothing but whitespace left.
    static func collapse(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let collapsed = words.joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        var cut = String(collapsed.prefix(limit - 1))
        while cut.last?.isWhitespace == true { cut.removeLast() }
        return cut + "…"
    }
}

struct CLIDailySummary: Sendable, Identifiable {
    let day: Date
    let totalCost: Double
    let totalTokens: Int
    /// The same tokens split by kind. `totalTokens == tokens.total` for Claude and
    /// Codex; for Grok the headline stays the CLI's own figure, which can disagree
    /// with the parts (see `GrokUsageAggregator`).
    let tokens: TokenBreakdown
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
    /// Today's tokens split by kind, with per-category dollars when the provider
    /// prices per category.
    let todayTokenBreakdown: TokenBreakdown
    let todayTurns: Int
    let weekCost: Double
    let monthCost: Double
    let byModelToday: [(model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)]
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
    /// The window's tokens split by kind. The headline `tokens` above is untouched —
    /// every existing caller reads it, and for Grok it can disagree with the parts.
    let breakdown: TokenBreakdown
    let turns: Int
    /// Ranked by cost, descending.
    let projects: [ProjectSummary]
    let models: [(model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)]

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
    /// Every chat with at least one turn in `[start, end]`, clipped to the range at
    /// day granularity. Default: none, until an aggregator keeps session aggregates.
    func sessions(from start: Date, to end: Date) async -> [SessionSummary]
}

extension CostLogAggregating {
    func sessions(from start: Date, to end: Date) async -> [SessionSummary] { [] }
}

actor JSONLAggregator: CostLogAggregating {
    static let shared = JSONLAggregator()

    private struct DayAgg {
        var cost = 0.0
        var tokens = 0
        var breakdown = TokenBreakdown.zero
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
        let breakdown: TokenBreakdown
        let turns: Int
        let byFamily: [String: Double]
    }

    /// One chat's sums, and nothing finer: per session, per agent, per day.
    ///
    /// A month of this Mac's transcripts is a few hundred of these and a few hundred
    /// kilobytes. Keeping the turns instead — which is what `recentTurns` costs — would
    /// pin tens of megabytes to draw a list of ten rows.
    ///
    /// There is deliberately no session-level total: every figure `sessions(from:to:)`
    /// reports is summed from `days`, so a revised turn has one place to be fixed and a
    /// clipped range can never disagree with an unclipped one.
    private struct SessionAgg: Codable {
        var projectSlug: String
        var firstAt: Date
        var lastAt: Date
        /// Ascending in practice — a transcript's turns arrive in near-chronological
        /// runs — but only `sessions(from:to:)` promises the order it hands out.
        var days: [DayTotals]
        /// Keyed by `agentId`.
        var agents: [String: AgentTotals]

        struct DayTotals: Codable {
            let day: Date
            var turns: Int
            var tokens: TokenBreakdown
            /// The main thread's share of `tokens`. The day is the only place that split
            /// survives clipping, so `SessionSummary.mainTokens` is summed from here.
            var mainTokens: TokenBreakdown
        }

        struct AgentTotals: Codable {
            var kind: String
            var model: String?
            var effort: String?
            var firstAt: Date
            var lastAt: Date
            var turns: Int
            var tokens: TokenBreakdown
        }

        init(projectSlug: String, at date: Date) {
            self.projectSlug = projectSlug
            self.firstAt = date
            self.lastAt = date
            self.days = []
            self.agents = [:]
        }

        /// The turn's counters, added where they belong. A day is found by its last
        /// entry first: turns arrive in near-chronological runs, so that is almost
        /// always the answer, and the linear fallback is over at most 92 entries.
        mutating func add(_ turn: CLITurn, on day: Date) {
            let isMain = turn.agentID == nil
            if let index = days.lastIndex(where: { $0.day == day }) {
                days[index].turns += 1
                days[index].tokens += turn.tokens
                if isMain { days[index].mainTokens += turn.tokens }
            } else {
                days.append(DayTotals(
                    day: day, turns: 1, tokens: turn.tokens,
                    mainTokens: isMain ? turn.tokens : .zero
                ))
            }

            guard let agentID = turn.agentID else { return }
            var agent = agents[agentID] ?? AgentTotals(
                // Every sub-agent transcript on this Mac carries `attributionAgent`;
                // the fallback is for shapes that predate it.
                kind: turn.agentKind ?? "sub-agent", model: nil, effort: nil,
                firstAt: turn.timestamp, lastAt: .distantPast, turns: 0, tokens: .zero
            )
            if turn.timestamp < agent.firstAt { agent.firstAt = turn.timestamp }
            if turn.timestamp >= agent.lastAt {
                // Last seen wins: an agent can be resumed on another model, and an
                // effort the record omits leaves the last one that said something.
                agent.lastAt = turn.timestamp
                agent.model = turn.model
                agent.effort = turn.effort ?? agent.effort
                if let kind = turn.agentKind { agent.kind = kind }
            }
            agent.turns += 1
            agent.tokens += turn.tokens
            agents[agentID] = agent
        }

        /// A later record for a message id already counted: the difference goes to the
        /// same day and the same agent, and the turn count does not move.
        mutating func revise(day: Date, delta: TokenBreakdown, isMain: Bool, agentID: String?) {
            if let index = days.lastIndex(where: { $0.day == day }) {
                days[index].tokens += delta
                if isMain { days[index].mainTokens += delta }
            }
            if let agentID, var agent = agents[agentID] {
                agent.tokens += delta
                agents[agentID] = agent
            }
        }

        /// Nothing older than the cutoff is kept: the ranges never ask for it, and a
        /// chat resumed for months would otherwise grow a row per day forever.
        mutating func drop(before cutoff: Date) {
            days.removeAll { $0.day < cutoff }
            agents = agents.filter { $0.value.lastAt >= cutoff }
        }
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
        /// One entry per chat: sums per agent and per day, never a turn. A busy month is
        /// a few hundred kilobytes beside the tens of megabytes `recentTurns` costs.
        let sessions: [String: SessionAgg]
        let titles: [String: String]
        let firstPrompts: [String: String]
    }

    /// 4: the snapshot carries one aggregate per chat, so a snapshot written before
    /// them has no chats to restore and would leave the session list empty until every
    /// transcript happened to be rewritten. Rejected wholesale, like 2 → 3 before it:
    /// one cold rebuild, then business as usual.
    ///
    /// 3: a turn's counters are the *last* record for its message id, not the first
    /// (see `ingest`). Every snapshot written before that holds provisional output
    /// counts, so it is rejected wholesale — one cold rebuild, then business as usual.
    private static let cacheVersion = 4

    private let rootURL: URL
    /// The calendar every day boundary in this actor comes from — the fold's, the
    /// daily rows', and the range `sessions(from:to:)` is asked about. One calendar so
    /// the bins and the query can never disagree.
    private let calendar: Calendar
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
    /// One entry per chat we have counted a turn for, keyed by Claude Code's
    /// `sessionId` — the spec's `sessions` map, named apart from the
    /// `sessions(from:to:)` method it feeds. Sums only; see `SessionAgg`.
    private var sessionAggs: [String: SessionAgg] = [:]
    /// `ai-title` per chat, the last one Claude Code wrote.
    private var titles: [String: String] = [:]
    /// The first human prompt per chat, already collapsed and cut — the name a chat
    /// with no `ai-title` goes by.
    private var firstPrompts: [String: String] = [:]
    private var initialized = false
    private let isoFormatter: ISO8601DateFormatter
    /// Same format without the fractional-seconds requirement. Real Claude Code logs
    /// always carry fractions, but a writer that stops doing so must not silently cost
    /// us every turn's timestamp.
    private let isoFormatterNoFraction: ISO8601DateFormatter
    private let mtimeWindow: TimeInterval = 90 * 24 * 3600
    /// How long a chat outlives its last turn. Two days longer than the ninety the
    /// History ranges reach, so a chat on the ninetieth day is still whole.
    private let sessionWindow: TimeInterval = 92 * 24 * 3600
    /// A name can arrive on a poll whose chunk carries no assistant record yet — Claude
    /// Code re-emits `ai-title` throughout a transcript — so an unknown session id is
    /// not proof the chat has none. Names are only swept when the two maps together
    /// pass this, which no real machine reaches.
    private let titleCap = 2_000
    /// The rolling figures reach back 30 days; keep turns one day longer so the
    /// month boundary is never clipped.
    private let recentWindow: TimeInterval = 31 * 24 * 3600
    /// Stable 64-bit hashes of message ids already counted, so duplicate log lines
    /// (re-scanned tails, forked sessions replaying old messages) never inflate cost.
    /// It spans every file, which is why it stays even though a repeat inside the
    /// recent window is now an update rather than a drop.
    private var seenMessageIDs: Set<UInt64> = []
    /// Where each recent turn sits in `recentTurns`, keyed by the same stable hash
    /// `seenMessageIDs` uses, so a later record for a known id can revise it in place.
    /// Rebuilt wherever `recentTurns` is rewritten wholesale — a cache load, a fold.
    private var recentIndexByID: [UInt64: Int] = [:]
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
    /// A nil `cacheURL` turns persistence off. The calendar is injectable too: it is
    /// the one that bins turns into days and the one `sessions(from:to:)` reads a
    /// range with, so a test can pin both to the same time zone.
    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        cacheURL: URL? = JSONLAggregator.defaultCacheURL,
        saveInterval: TimeInterval = 300,
        calendar: Calendar = .current
    ) {
        self.rootURL = rootURL
        self.cacheURL = cacheURL
        self.saveInterval = saveInterval
        self.calendar = calendar
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
        let startOfDay = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        var todayCost = 0.0
        var todayTokens = 0
        var todayTokenBreakdown = TokenBreakdown.zero
        var todayTurns = 0
        var weekCost = 0.0
        var monthCost = 0.0
        var byModelToday: [String: (cost: Double, tokens: Int, breakdown: TokenBreakdown)] = [:]
        var dailyAcc = oldDays
        var projectsWeekAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var projectsMonthAcc: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]

        for t in recentTurns {
            let c = t.cost
            let tokens = t.totalTokens
            if t.timestamp >= startOfDay {
                todayCost += c
                todayTokens += tokens
                todayTokenBreakdown += t.tokens
                todayTurns += 1
                if let modelDisplay = ModelPricing.displayName(for: t.model) {
                    let p = byModelToday[modelDisplay] ?? (0, 0, .zero)
                    byModelToday[modelDisplay] = (p.cost + c, p.tokens + tokens, p.breakdown + t.tokens)
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
            bucket.breakdown += t.tokens
            bucket.turns += 1
            bucket.byFamily[ModelPricing.family(for: t.model), default: 0] += c
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
            todayTokenBreakdown: todayTokenBreakdown,
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
        // Not `breakdown`: the actor already has a `breakdown()` method, and a local of
        // that name would shadow it.
        var windowBreakdown = TokenBreakdown.zero
        var turns = 0
        var byProject: [String: (cost: Double, tokens: Int, turns: Int, lastActivity: Date)] = [:]
        var byModel: [String: (cost: Double, tokens: Int, breakdown: TokenBreakdown)] = [:]

        for t in recentTurns where t.timestamp >= start && t.timestamp <= end {
            let c = t.cost
            let tok = t.totalTokens
            cost += c
            tokens += tok
            windowBreakdown += t.tokens
            turns += 1

            var p = byProject[t.projectSlug] ?? (0, 0, 0, t.timestamp)
            p.cost += c
            p.tokens += tok
            p.turns += 1
            p.lastActivity = max(p.lastActivity, t.timestamp)
            byProject[t.projectSlug] = p

            if let modelDisplay = ModelPricing.displayName(for: t.model) {
                let m = byModel[modelDisplay] ?? (0, 0, .zero)
                byModel[modelDisplay] = (m.cost + c, m.tokens + tok, m.breakdown + t.tokens)
            }
        }

        return WindowUsage(
            start: start,
            end: end,
            cost: cost,
            tokens: tokens,
            breakdown: windowBreakdown,
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
                .map { ($0.key, $0.value.cost, $0.value.tokens, $0.value.breakdown) }
                .sorted { $0.1 > $1.1 }
        )
    }

    /// Every chat with a turn inside the range, clipped to it at day granularity.
    ///
    /// Day granularity is what makes this cheap and what makes a five-hour window mean
    /// "today": the aggregate keeps a day's sums, not a turn's, so a range is read as
    /// the local days it touches — `[startOfDay(start) … startOfDay(end)]`. A window
    /// shorter than a day therefore widens to the day it falls in, which is what the
    /// History subtitle says out loud.
    ///
    /// `firstAt` and `lastAt` are the chat's own and are never clipped: a row's job is
    /// to identify the chat, and "this one started three months ago" is information.
    func sessions(from start: Date, to end: Date) async -> [SessionSummary] {
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        guard firstDay <= lastDay else { return [] }
        let afterLastDay = calendar.date(byAdding: .day, value: 1, to: lastDay)
            ?? lastDay.addingTimeInterval(86_400)
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(sessionAggs.count)

        for (id, agg) in sessionAggs {
            let days = agg.days
                .filter { $0.day >= firstDay && $0.day <= lastDay && $0.turns > 0 }
                .sorted { $0.day < $1.day }
            guard !days.isEmpty else { continue }

            var turns = 0
            var tokens = TokenBreakdown.zero
            var mainTokens = TokenBreakdown.zero
            for day in days {
                turns += day.turns
                tokens += day.tokens
                mainTokens += day.mainTokens
            }

            // An agent's own days are not stored — it runs inside one turn of the parent
            // and hardly ever crosses midnight — so an agent is in the range whole or
            // not at all.
            let agents = agg.agents
                .filter { $0.value.lastAt >= firstDay && $0.value.firstAt < afterLastDay }
                .map { entry in
                    SessionAgentSummary(
                        id: entry.key,
                        kind: entry.value.kind,
                        model: entry.value.model,
                        effort: entry.value.effort,
                        firstAt: entry.value.firstAt,
                        lastAt: entry.value.lastAt,
                        turns: entry.value.turns,
                        tokens: entry.value.tokens
                    )
                }
                .sorted { lhs, rhs in
                    let l = lhs.tokens.cost?.total ?? 0
                    let r = rhs.tokens.cost?.total ?? 0
                    return l == r ? lhs.id < rhs.id : l > r
                }

            summaries.append(SessionSummary(
                id: id,
                providerID: "claude",
                title: titles[id] ?? firstPrompts[id],
                projectSlug: agg.projectSlug,
                origin: nil,
                firstAt: agg.firstAt,
                lastAt: agg.lastAt,
                turns: turns,
                tokens: tokens,
                mainTokens: mainTokens,
                agents: agents,
                days: days.map {
                    SessionDaySummary(day: $0.day, turns: $0.turns, tokens: $0.tokens)
                }
            ))
        }

        return summaries.sorted { $0.lastAt == $1.lastAt ? $0.id < $1.id : $0.lastAt > $1.lastAt }
    }

    // MARK: - Ingest

    /// One response is one turn, however many lines log it — but the *last* line is the
    /// one that says what the response cost. Claude Code writes 2–4 `type: assistant`
    /// lines per response under the same `message.id`: the first carries a provisional
    /// usage (`output_tokens: 2`, no thinking, `stop_reason: null`) and later ones the
    /// final counts. Keeping the first and dropping the rest is what the dedupe used to
    /// do, and it threw away most of the output on this machine's own logs.
    private func ingest(_ records: [ParsedRecord]) {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        for record in records {
            switch record {
            case .title(let sessionID, let title):
                if titles[sessionID] != title {
                    titles[sessionID] = title
                    dirty = true
                }
                continue
            case .prompt(let sessionID, let text):
                // The first one wins: a transcript is read in order, and every later
                // prompt is the same chat still going.
                if firstPrompts[sessionID] == nil {
                    firstPrompts[sessionID] = text
                    dirty = true
                }
                continue
            case .turn(let turn):
                let hash = Self.stableHash(turn.id)
                // A repeat of an id we already hold is the same response told again, with
                // better numbers; anything else about it (time, model, project) is settled
                // by the first record.
                guard seenMessageIDs.insert(hash).inserted else {
                    replaceIfLater(turn, hash: hash)
                    continue
                }
                // Synthetic / internal Claude Code events aren't user-facing models.
                if ModelPricing.isSynthetic(turn.model) { continue }
                applyToSession(turn)
                if turn.timestamp < recentCutoff {
                    fold(turn)
                } else {
                    recentIndexByID[hash] = recentTurns.count
                    recentTurns.append(turn)
                }
            }
        }
    }

    /// Adopts a later record's counters for a turn we already hold.
    ///
    /// "Later" is decided by the output count, not by line order: a re-scanned tail or a
    /// forked session can replay the provisional record after the final one, and that
    /// must not shrink the turn. Equal counts keep what is stored — measured over this
    /// machine's transcripts, no message id ever changes anything else once its output
    /// stops growing.
    ///
    /// Ids already folded into `oldDays` — turns older than `recentWindow` — are not in
    /// the index and are never revised: the fold is a day-level sum with no per-turn slot
    /// left to replace. Those records are weeks old and have long since stopped growing.
    private func replaceIfLater(_ turn: CLITurn, hash: UInt64) {
        guard let index = recentIndexByID[hash], index < recentTurns.count else { return }
        let stored = recentTurns[index]
        guard turn.tokens.output > stored.tokens.output else { return }
        recentTurns[index] = CLITurn(
            id: stored.id,
            timestamp: stored.timestamp,
            model: stored.model,
            tokens: turn.tokens,
            projectSlug: stored.projectSlug,
            sessionID: stored.sessionID,
            agentID: stored.agentID,
            agentKind: stored.agentKind,
            effort: stored.effort
        )
        reviseSession(from: stored, to: turn)
        dirty = true
    }

    /// The chat's sums took the stored counters when the turn arrived; the difference
    /// belongs to the same day and the same agent. Ids already folded out of
    /// `recentTurns` never reach here, so a chat is revised exactly where `recentTurns`
    /// is — and, like `oldDays`, is left alone where it is not.
    private func reviseSession(from stored: CLITurn, to replacement: CLITurn) {
        guard !stored.sessionID.isEmpty, var agg = sessionAggs[stored.sessionID] else { return }
        agg.revise(
            day: dayStart(for: stored.timestamp),
            delta: Self.minus(replacement.tokens, stored.tokens),
            isMain: stored.agentID == nil,
            agentID: stored.agentID
        )
        sessionAggs[stored.sessionID] = agg
    }

    /// `recentTurns` is append-only apart from the fold, so the index only has to be
    /// rebuilt where the array is replaced wholesale.
    private func rebuildRecentIndex() {
        recentIndexByID.removeAll(keepingCapacity: true)
        recentIndexByID.reserveCapacity(recentTurns.count)
        for (i, t) in recentTurns.enumerated() {
            recentIndexByID[Self.stableHash(t.id)] = i
        }
    }

    private func fold(_ t: CLITurn) {
        let day = dayStart(for: t.timestamp)
        var agg = oldDays[day] ?? DayAgg()
        agg.cost += t.cost
        agg.tokens += t.totalTokens
        agg.breakdown += t.tokens
        agg.turns += 1
        agg.byFamily[ModelPricing.family(for: t.model), default: 0] += t.cost
        oldDays[day] = agg
    }

    /// A chat's sums take the turn once, when it first arrives — before the branch that
    /// decides whether it joins `recentTurns` or goes straight into `oldDays`. That is
    /// why the fold has nothing to do here: a turn ageing out of `recentTurns` was
    /// already counted when it was read.
    private func applyToSession(_ turn: CLITurn) {
        guard !turn.sessionID.isEmpty else { return }
        var agg = sessionAggs[turn.sessionID]
            ?? SessionAgg(projectSlug: turn.projectSlug, at: turn.timestamp)
        if turn.timestamp < agg.firstAt { agg.firstAt = turn.timestamp }
        if turn.timestamp >= agg.lastAt {
            agg.lastAt = turn.timestamp
            // The chat's project follows its latest turn, the same rule Codex's file
            // uses for the latest `turn_context.cwd`: a chat resumed somewhere else
            // belongs where it is now.
            agg.projectSlug = turn.projectSlug
        }
        agg.add(turn, on: dayStart(for: turn.timestamp))
        sessionAggs[turn.sessionID] = agg
        dirty = true
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
            rebuildRecentIndex()
            dirty = true
        }
        let dayCutoff = dayStart(for: Date().addingTimeInterval(-mtimeWindow))
        if oldDays.keys.contains(where: { $0 < dayCutoff }) {
            oldDays = oldDays.filter { $0.key >= dayCutoff }
            dirty = true
        }
        let sessionCutoff = dayStart(for: Date().addingTimeInterval(-sessionWindow))
        var sessionsChanged = false
        // A snapshot of the keys: the loop rewrites the dictionary it walks.
        for id in Array(sessionAggs.keys) {
            guard var agg = sessionAggs[id] else { continue }
            if agg.lastAt < sessionCutoff {
                sessionAggs.removeValue(forKey: id)
                titles.removeValue(forKey: id)
                firstPrompts.removeValue(forKey: id)
                sessionsChanged = true
                continue
            }
            let before = (agg.days.count, agg.agents.count)
            agg.drop(before: sessionCutoff)
            if (agg.days.count, agg.agents.count) != before {
                sessionAggs[id] = agg
                sessionsChanged = true
            }
        }
        // Names whose chat we have never seen a turn for: kept until there are enough of
        // them to be worth sweeping, because the chunk that named the chat can arrive
        // before the chunk that pays for it.
        if titles.count + firstPrompts.count > titleCap {
            let known = Set(sessionAggs.keys)
            let counts = (titles.count, firstPrompts.count)
            titles = titles.filter { known.contains($0.key) }
            firstPrompts = firstPrompts.filter { known.contains($0.key) }
            if (titles.count, firstPrompts.count) != counts { sessionsChanged = true }
        }
        if sessionsChanged { dirty = true }
    }

    private func dayStart(for date: Date) -> Date {
        if let c = dayCache, date >= c.start, date < c.next { return c.start }
        let cal = calendar
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

    /// `a - b`, for the one case this file has: a turn whose provisional counters were
    /// already added to a chat's sums and now have to be swapped for the real ones.
    /// Both sides come from the same parser and are priced, so the dollars subtract with
    /// the tokens; a side without dollars leaves the difference without them, exactly as
    /// `TokenBreakdown.+` does. Overflow clamps rather than traps — the counters come
    /// out of log files nobody validates.
    private static func minus(_ a: TokenBreakdown, _ b: TokenBreakdown) -> TokenBreakdown {
        var delta = TokenBreakdown(
            input: subtracting(a.input, b.input),
            output: subtracting(a.output, b.output),
            cacheRead: subtracting(a.cacheRead, b.cacheRead),
            cacheWrite5m: subtracting(a.cacheWrite5m, b.cacheWrite5m),
            cacheWrite1h: subtracting(a.cacheWrite1h, b.cacheWrite1h),
            thinking: subtracting(a.thinking, b.thinking)
        )
        if let ac = a.cost, let bc = b.cost {
            delta.cost = TokenCostBreakdown(
                input: ac.input - bc.input,
                output: ac.output - bc.output,
                cacheRead: ac.cacheRead - bc.cacheRead,
                cacheWrite: ac.cacheWrite - bc.cacheWrite
            )
        }
        return delta
    }

    private static func subtracting(_ lhs: Int, _ rhs: Int) -> Int {
        let (difference, overflowed) = lhs.subtractingReportingOverflow(rhs)
        guard overflowed else { return difference }
        return rhs > 0 ? .min : .max
    }

    /// Which project a transcript belongs to: the log root's own child directory.
    ///
    /// A main session is `<root>/<slug>/<sessionId>.jsonl`, a sub-agent's is
    /// `<root>/<slug>/<sessionId>/subagents/agent-<id>.jsonl` and a workflow journal one
    /// level deeper again. Taking the file's parent directory — which this did — named
    /// every sub-agent's project "subagents": a row for a project that does not exist,
    /// with spend taken off the project that really paid for it.
    static func projectSlug(for url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents
        else { return url.deletingLastPathComponent().lastPathComponent }
        return components[rootComponents.count]
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
    private func parseFile(at url: URL, from start: UInt64, size: UInt64, mtime: Date) -> [ParsedRecord] {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return [] }
        guard let data = try? handle.readToEnd() else { return [] }

        // Claude Code stores a session at ~/.claude/projects/<project-slug>/<uuid>.jsonl
        // and its sub-agents under <project-slug>/<uuid>/subagents/.
        let projectSlug = Self.projectSlug(for: url, root: rootURL)
        var records: [ParsedRecord] = []
        var pool = StringPool()
        var consumedInChunk = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var lineStart = 0
            for i in 0..<raw.count {
                if raw.load(fromByteOffset: i, as: UInt8.self) == 0x0A {
                    if i > lineStart {
                        let line = Data(bytes: base.advanced(by: lineStart), count: i - lineStart)
                        if let record = Self.parseRecord(
                            line, projectSlug: projectSlug, iso: isoFormatter,
                            isoNoFraction: isoFormatterNoFraction, pool: &pool
                        ) {
                            records.append(record)
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
        return records
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
        // Without this the ids restored into `seenMessageIDs` would be known but
        // unreachable, and a final record arriving after a relaunch would be dropped
        // instead of replacing its provisional turn.
        rebuildRecentIndex()
        // Last one wins rather than merged: a day repeated in a hand-edited file is
        // corruption, and counting it twice would be worse than dropping half of it.
        var days: [Date: DayAgg] = [:]
        for entry in snapshot.oldDays {
            days[entry.day] = DayAgg(
                cost: entry.cost, tokens: entry.tokens, breakdown: entry.breakdown,
                turns: entry.turns, byFamily: entry.byFamily
            )
        }
        oldDays = days
        seenMessageIDs = Set(snapshot.seenMessageIDs)
        sessionAggs = snapshot.sessions
        titles = snapshot.titles
        firstPrompts = snapshot.firstPrompts
        NSLog(
            "[UT] cost cache restored: %ld files, %ld recent turns, %ld chats",
            fileMarks.count, recentTurns.count, sessionAggs.count
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
                         breakdown: $0.value.breakdown, turns: $0.value.turns,
                         byFamily: $0.value.byFamily)
            },
            seenMessageIDs: Array(seenMessageIDs),
            sessions: sessionAggs,
            titles: titles,
            firstPrompts: firstPrompts
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

    /// One log line → what it says, as a pure function of the bytes: `static` and
    /// formatter-injected so a test can read a record's identity straight out of a line
    /// copied from a real transcript, with no actor and no log root.
    static func parseRecord(
        _ data: Data,
        projectSlug: String,
        iso: ISO8601DateFormatter,
        isoNoFraction: ISO8601DateFormatter,
        pool: inout StringPool
    ) -> ParsedRecord? {
        guard let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = any["type"] as? String else { return nil }
        switch type {
        case "assistant":
            return parseTurn(
                any, projectSlug: projectSlug, iso: iso, isoNoFraction: isoNoFraction, pool: &pool
            ).map(ParsedRecord.turn)
        case "ai-title":
            guard let sessionID = any["sessionId"] as? String, !sessionID.isEmpty,
                  let title = SessionTitle.clean(any["aiTitle"] as? String)
            else { return nil }
            return .title(sessionID: pool.intern(sessionID), title: title)
        case "user":
            // Only the user's own prompt names a chat. Everything else Claude Code
            // writes as `type: user` — tool results, the `<local-command-caveat>` meta
            // records, task notifications, a sub-agent's brief — carries no `origin` or
            // another kind, and would name the chat after the tool's own plumbing.
            // `promptSource` is deliberately not part of this: a session driven through
            // the SDK says `sdk` on a prompt the user really typed.
            guard (any["origin"] as? [String: Any])?["kind"] as? String == "human",
                  (any["isSidechain"] as? Bool) != true,
                  let sessionID = any["sessionId"] as? String, !sessionID.isEmpty,
                  let message = any["message"] as? [String: Any],
                  let text = SessionTitle.firstPrompt(from: message["content"])
            else { return nil }
            return .prompt(sessionID: pool.intern(sessionID), text: text)
        default:
            return nil
        }
    }

    private static func parseTurn(
        _ any: [String: Any],
        projectSlug: String,
        iso: ISO8601DateFormatter,
        isoNoFraction: ISO8601DateFormatter,
        pool: inout StringPool
    ) -> CLITurn? {
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
            // The TTL object is the authoritative split, and the aggregate beside it in
            // the same line restates the sum — reading both would double the write.
            c5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
            c1h = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
        } else if let aggregate = usage["cache_creation_input_tokens"] as? Int, aggregate > 0 {
            // No TTL object: the tokens were written and charged, but nothing says at
            // which tier. Billing them as 5-minute writes is the conservative reading —
            // it is the tier Claude Code uses unless a caller opts into the 1-hour cache,
            // and the cheaper of the two rates, so an unknown TTL never inflates the
            // bill. Dropping them, which is what this did, lost real spend outright.
            c5 = aggregate
        }

        // New in the logs; absent in everything written before it, hence the default.
        let thinking = (usage["output_tokens_details"] as? [String: Any])
            .flatMap { $0["thinking_tokens"] as? Int } ?? 0

        let tsStr = (any["timestamp"] as? String) ?? ""
        // A line we can't date must be dropped, not billed as "now": the old
        // `?? Date()` put a turn from an unparseable line into today's spend and into
        // whatever rate window happens to be open, which is the one place a wrong
        // answer is worse than no answer. Fractions first (what Claude Code writes),
        // then plain ISO8601 for a writer that stops emitting them.
        guard let ts = iso.date(from: tsStr) ?? isoNoFraction.date(from: tsStr)
        else { return nil }
        // Older logs may lack a message id — fall back to a content identity so exact
        // duplicate lines still dedupe. `thinking` is part of that identity: two
        // otherwise identical turns that reasoned differently are two turns.
        //
        // The counts are in the key, so the provisional and final records of one id-less
        // response are two identities and both count — deliberately: with no id there is
        // nothing to tie them together, and treating a bigger-output line as an update of
        // a smaller one would silently merge two genuinely distinct turns. Only builds
        // old enough to omit the id are affected, and they are the ones that logged a
        // single line per response.
        let id = msgID.isEmpty
            ? "\(tsStr)|\(model)|\(input)|\(output)|\(cacheRead)|\(c5)|\(c1h)|\(thinking)"
            : msgID

        return CLITurn(
            id: id,
            timestamp: ts,
            model: model,
            tokens: TokenBreakdown(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite5m: c5,
                cacheWrite1h: c1h,
                thinking: thinking
            ).priced(model: model),
            projectSlug: projectSlug,
            // The record's own fields, never the file name: a sub-agent transcript is
            // named after the agent, and nothing but the record says which chat it
            // belongs to or what kind of agent wrote it.
            sessionID: pool.intern((any["sessionId"] as? String) ?? ""),
            agentID: (any["agentId"] as? String).map { pool.intern($0) },
            agentKind: (any["attributionAgent"] as? String).map { pool.intern($0) },
            effort: (any["effort"] as? String).map { pool.intern($0) }
        )
    }
}
