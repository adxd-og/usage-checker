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
/// A rollout written by a recent CLI carries one `token_usage_record` per API response,
/// written just before that response's `token_count`. Those records are the bill: the
/// cumulative counter resets after long pauses and never includes compaction calls (on
/// this Mac's 2026-09-06 17:25 session the records sum to 3,783,861 against the
/// counter's 3,523,616 — 7 % of the session invisible to counters). A file that writes
/// no records is billed from the counter's deltas exactly as before, and the decision is
/// per file, not per CLI version: some 0.153 rollouts write only `token_count`.
///
/// Nothing here is persisted. Unlike `JSONLAggregator`, which keeps a versioned
/// `cost-cache-claude-v1.json` and has to discard it when the billing rule changes,
/// this aggregator rebuilds its parse state, its turns and its session aggregates from
/// the rollout tree on every launch — the 90-day mtime window keeps that cheap — so a
/// rule change takes effect the first time the new build runs and no stale figure can
/// outlive it.
///
/// Codex's `input_tokens` *includes* both the cached input and the tokens written to
/// cache, so fresh input is OpenAI's `ordinary_input_tokens`: `input − cached −
/// cache_write`. Each of the three bills at its own rate — cache writes at 1.25× the
/// uncached input rate from GPT-5.6 on, cached reads at 0.1× — and each is one bucket of
/// the breakdown. `reasoning_output_tokens` is a subset of `output_tokens` and never
/// joins the total.
actor CodexUsageAggregator: CostLogAggregating {
    static let shared = CodexUsageAggregator()

    /// One billed API response: a `token_usage_record`, or — in a file that writes
    /// none — one `token_count` delta.
    private struct Turn: Sendable {
        let timestamp: Date
        let model: String
        /// The reasoning effort the `turn_context` named. nil in a rollout old enough
        /// not to write one.
        let effort: String?
        let projectSlug: String
        /// Priced when read and again whenever the live table changes (`repriceIfTableChanged`).
        var cost: Double
        var tokens: TokenBreakdown
        /// The chat this turn belongs to — a sub-agent's turns carry the PARENT's
        /// `session_id`, which is what makes them part of the same chat.
        let sessionID: String
        /// The thread that spent the tokens: the session's own id on the main thread,
        /// the agent's on a sub-agent rollout.
        let threadID: String
        /// Set exactly when the file is a sub-agent rollout; then it equals `threadID`.
        let agentID: String?
        /// `agent_nickname`, or `agent_path` when the nickname is missing.
        let agentKind: String?
        /// The `originator` of the rollout that produced the turn.
        let origin: String?
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

    /// What a `turn_context` says about the turn it opens.
    struct TurnContext: Equatable, Sendable {
        var model: String?
        var effort: String?
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
        /// The reasoning effort of the latest `turn_context`, carried the same way.
        var currentEffort: String?
        /// The `session_meta` cwd, percent-encoded — see `encode(cwd:)`.
        var projectSlug: String?
        /// Cumulative counters as of the previous `token_count` event.
        var prev = Counters()
        /// Deltas seen before the file named a model, summed. The first `turn_context`
        /// that follows adopts them as one turn; a file that never names a model leaves
        /// them here, unrecorded — there is nothing to price or label them with.
        var pendingTokens: TokenBreakdown?
        /// When those tokens were first spent — the timestamp the recovered turn carries.
        var pendingSince: Date?
        /// True from the first top-level `token_usage_record` this file writes. From
        /// then on the records are the bill and `token_count` is only a baseline: the
        /// counter is cumulative but never includes compaction calls, so a file that
        /// has both would lose that spend if it billed from the counter, and would
        /// double every response if it billed from both.
        var sawRecord = false
        /// FNV-1a hashes of `thread_id|response_id` for the responses this file has
        /// already billed, so a re-read tail never bills one twice. Bounded by the
        /// number of responses in one rollout (tens), and pruned with the file's state.
        var seenResponses: Set<UInt64> = []
        /// `turn_context` by `turn_id` — a record names the turn it belongs to, and a
        /// rollout can carry several models and efforts after a resume.
        var contexts: [String: TurnContext] = [:]
        /// The latest `turn_context`, whatever its id: the label for a record whose
        /// `turn_id` this file has no context for (a sub-agent rollout opens with the
        /// parent's root turn).
        var latestContext: TurnContext?
        /// Identity, from the FIRST `session_meta` in the file and nothing else.
        var sawMeta = false
        var sessionID: String?
        var threadID: String?
        var isSubagent = false
        var agentKind: String?
        var origin: String?
        /// Set once this file has contributed a first prompt, so the rest of its
        /// `response_item` lines are skipped instead of re-examined.
        var sawPrompt = false
    }

    /// One local day of a chat. `mainTokens` is kept alongside `tokens` because a
    /// clipped summary has to answer "how much of this range was the main thread?" and
    /// `SessionDaySummary` carries only the combined figure.
    struct DaySlice: Equatable, Sendable {
        var turns = 0
        var tokens = TokenBreakdown.zero
        var mainTokens = TokenBreakdown.zero
    }

    /// One sub-agent thread of a chat.
    struct AgentAgg: Equatable, Sendable {
        var kind: String
        var model: String?
        var effort: String?
        var firstAt: Date
        var lastAt: Date
        var turns: Int
        var tokens: TokenBreakdown
    }

    /// One (model, effort) pair of a chat. The pair is kept in the value as well as in
    /// the key: a model id is a slug from a log nobody validates, and splitting the key
    /// back apart on "|" would be a second parser.
    struct ModelAgg: Equatable, Sendable {
        var model: String
        var effort: String?
        var turns: Int
        var tokens: TokenBreakdown
    }

    /// One chat: the main thread, its sub-agents, and its days. Kept for 92 days
    /// (`sessionRetention`), independently of `recentTurns`, so a chat that started
    /// last month still shows its whole span.
    ///
    /// The days are two tiers, told apart by where a response is and never by its date
    /// (issue #13): `recentByDay` sums the chat's turns in `recentTurns`, `byDay` every
    /// turn folded out of it or older than the window when read. A turn is in one
    /// tier, so a re-bin into another zone — the recent tier rebuilt from the turns,
    /// the folded one re-keyed by `DayRekey.midpoint` — neither counts it twice nor
    /// loses it. `summary` reads the two added up.
    struct SessionAgg: Equatable, Sendable {
        var projectSlug: String
        var origin: String?
        var firstAt: Date
        var lastAt: Date
        var turns = 0
        var tokens = TokenBreakdown.zero
        var mainTokens = TokenBreakdown.zero
        /// The folded tier.
        var byDay: [Date: DaySlice] = [:]
        /// The recent tier: rebuilt from `recentTurns` on a re-bin and after a fold.
        var recentByDay: [Date: DaySlice] = [:]
        var agents: [String: AgentAgg] = [:]
        /// Keyed by `SessionModelSummary.key(model:effort:)`. The main thread's turns
        /// and its sub-agents' both land here: the row answers what the chat spent on a
        /// model, not which thread spent it.
        var byModel: [String: ModelAgg] = [:]
        /// False until a main-thread turn has named the project and the originator. A
        /// sub-agent file can be read first — the enumerator's order is not the
        /// session's — and its slug and origin stand in until the parent's arrive.
        var hasMainIdentity = false
    }

    private let rootURL: URL
    /// `~/.codex/archived_sessions` — the same rollouts, moved out of the dated tree.
    /// nil when the injected root is not a Codex home (see `sibling(of:named:)`).
    private let archivedURL: URL?
    /// `~/.codex/session_index.jsonl`, read in Task 5. Derived the same way.
    private let indexURL: URL?
    /// The calendar every day boundary is taken in: the system's own by default, which
    /// follows a time-zone change while the app runs. Injected so a session test can
    /// pin UTC instead of drifting with the machine's time zone; replaced, and the
    /// chats re-binned, by `timeZoneDidChange(calendar:)`.
    private var calendar: Calendar
    /// Per rollout, keyed by `fileKey(for:)` — the thread uuid, not the path.
    private var fileStates: [String: FileState] = [:]
    /// Turns young enough to feed the rolling today/week/month figures; older ones fold
    /// into `oldDays` and are released.
    private var recentTurns: [Turn] = []
    private var oldDays: [Date: DayAgg] = [:]
    private var sessionAggs: [String: SessionAgg] = [:]
    /// `thread_name` per session id, from `~/.codex/session_index.jsonl`.
    private var names: [String: String] = [:]
    /// What the index looked like when it was last read. The file is rewritten on every
    /// rename, so size-and-mtime is enough to skip re-parsing it on a quiet poll.
    private var indexMark: (size: UInt64, mtime: Date)?
    /// The first thing the user typed in a chat, for the chats Codex never named — it
    /// writes no index entry for `codex exec` sessions. Kept with the timestamp so the
    /// earliest wins when a session spans two rollouts.
    private var firstPrompts: [String: (text: String, at: Date)] = [:]
    /// A rollout untouched for longer than this is outside every figure we show, so it
    /// is never parsed. A year and a day, to match `dayRetention` below: the Activity
    /// cards reach back 365 days, and a file must still be readable on the last day it
    /// can contribute to one.
    private let mtimeWindow: TimeInterval = 366 * 24 * 3600
    /// How long a day total survives in `oldDays`. A constant of its own, not
    /// `mtimeWindow` again — see issue #7, where one name answered both questions and
    /// the "Last year" card could never exceed "Last 90 days".
    private let dayRetention: TimeInterval = 366 * 24 * 3600
    /// The rolling figures reach back 30 days; keep turns one day longer so the month
    /// boundary is never clipped.
    private let recentWindow: TimeInterval = 31 * 24 * 3600
    /// Chats are kept three times longer than turns: the History list reaches back a
    /// quarter and holds one small aggregate per chat, not one record per turn.
    private let sessionRetention: TimeInterval = 92 * 24 * 3600
    /// The day the last lookup fell in, dropped on a system time-zone change.
    private let dayBins = DayBinCache()
    /// The `ModelPricing.generation` the turns in `recentTurns` were last priced at. nil
    /// before the first scan.
    private var pricedGeneration: Int?

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
    /// `~/.codex/sessions`. The archive and the name index are derived from it rather
    /// than passed separately, so the app injects one path and a test injects one path.
    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        archivedURL: URL? = nil,
        indexURL: URL? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.rootURL = rootURL
        self.archivedURL = archivedURL ?? Self.sibling(of: rootURL, named: "archived_sessions")
        self.indexURL = indexURL ?? Self.sibling(of: rootURL, named: "session_index.jsonl")
        self.calendar = calendar
    }

    /// `archived_sessions` and `session_index.jsonl` are siblings of the sessions root
    /// inside `~/.codex`. They are derived only when the root really is named
    /// `sessions`: a suite that injects its own temp directory then reads neither, and
    /// stays hermetic without having to pass three paths at every construction site.
    nonisolated static func sibling(of root: URL, named name: String) -> URL? {
        guard root.lastPathComponent == "sessions" else { return nil }
        return root.deletingLastPathComponent().appendingPathComponent(name)
    }

    func refresh() async {
        ingestAll()
    }

    /// Week / today dollars for the menu-bar popover and `CodexProvider`, which ask for
    /// them without going through `refresh()`.
    func costs(now: Date = Date()) -> (week: Double, today: Double) {
        ingestAll()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        // This aggregator's calendar, the one `dayStart` bins the daily rows with: a
        // fresh `Calendar.current` here put "today" and today's row on two different
        // midnights whenever the two disagreed.
        let startOfDay = calendar.startOfDay(for: now)
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
        breakdown(now: Date())
    }

    /// `breakdown()` as of `now`: "today" is `now`'s day in this aggregator's calendar,
    /// the same one the daily rows are binned in.
    func breakdown(now: Date) -> CLIBreakdown {
        let startOfDay = calendar.startOfDay(for: now)
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

    /// One chat as § 1 defines it, clipped to `[start, end]` at local-day granularity:
    /// the days outside the range are dropped and the totals re-summed from what is
    /// left, which is also how a range shorter than a day (the History tab's 5h) widens
    /// to the day it falls in. `firstAt` / `lastAt` stay the chat's own span — the row
    /// says when the chat ran, not when the range starts. Returns nil when no day of
    /// the chat falls inside the range.
    nonisolated static func summary(
        sessionID: String,
        agg: SessionAgg,
        title: String?,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) -> SessionSummary? {
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.startOfDay(for: end)
        // Both tiers: a day can have a share in each (a zone change, a fold part-way
        // through it), and the two add up.
        var days = agg.byDay.filter { $0.key >= lower && $0.key <= upper }
        for (day, slice) in agg.recentByDay where day >= lower && day <= upper {
            var merged = days[day] ?? DaySlice()
            merged.turns += slice.turns
            merged.tokens += slice.tokens
            merged.mainTokens += slice.mainTokens
            days[day] = merged
        }
        guard !days.isEmpty else { return nil }

        var turns = 0
        var tokens = TokenBreakdown.zero
        var mainTokens = TokenBreakdown.zero
        var daySummaries: [SessionDaySummary] = []
        daySummaries.reserveCapacity(days.count)
        for (day, slice) in days.sorted(by: { $0.key < $1.key }) {
            turns += slice.turns
            tokens += slice.tokens
            mainTokens += slice.mainTokens
            daySummaries.append(
                SessionDaySummary(day: day, turns: slice.turns, tokens: slice.tokens)
            )
        }

        // Agents are kept or dropped whole: only their span is stored, not a per-day
        // split, so an agent that ran inside the range contributes all of its tokens.
        let upperExclusive = calendar.date(byAdding: .day, value: 1, to: upper)
            ?? upper.addingTimeInterval(86_400)
        let agents = agg.agents
            .filter { $0.value.lastAt >= lower && $0.value.firstAt < upperExclusive }
            .map { id, a in
                SessionAgentSummary(
                    id: id, kind: a.kind, model: a.model, effort: a.effort,
                    firstAt: a.firstAt, lastAt: a.lastAt, turns: a.turns, tokens: a.tokens
                )
            }
            .sorted {
                let l = $0.tokens.cost?.total ?? 0
                let r = $1.tokens.cost?.total ?? 0
                return l == r ? $0.id < $1.id : l > r
            }

        // Kept whole, whatever the range clipped: no per-model day split is stored, so
        // a row is the chat's own total or nothing at all. Sorted here as well as in
        // `SessionListRule`, the way agents are.
        let models = agg.byModel.values
            .map {
                SessionModelSummary(
                    model: $0.model, effort: $0.effort, turns: $0.turns, tokens: $0.tokens
                )
            }
            .sorted {
                let l = $0.tokens.cost?.total ?? 0
                let r = $1.tokens.cost?.total ?? 0
                return l == r ? $0.id < $1.id : l > r
            }

        return SessionSummary(
            id: sessionID,
            providerID: "codex",
            title: title,
            projectSlug: agg.projectSlug,
            origin: agg.origin,
            firstAt: agg.firstAt,
            lastAt: agg.lastAt,
            turns: turns,
            tokens: tokens,
            mainTokens: mainTokens,
            agents: agents,
            days: daySummaries,
            models: models
        )
    }

    /// Every chat with a day inside the range, newest first. Reads what `refresh()` has
    /// already ingested, the way `breakdown()` and `usage(from:to:)` do.
    ///
    /// Spelled `async` — unlike `breakdown()`, which is not — to match
    /// `CostLogAggregating.sessions(from:to:)` exactly. That requirement has a default
    /// implementation returning `[]`, and a non-`async` method here would merely be an
    /// overload of it: a direct call on `CodexUsageAggregator` then resolves to the
    /// protocol extension and every chat silently disappears.
    func sessions(from start: Date, to end: Date) async -> [SessionSummary] {
        sessionAggs
            .compactMap {
                Self.summary(
                    sessionID: $0.key, agg: $0.value, title: title(for: $0.key),
                    from: start, to: end, calendar: calendar
                )
            }
            .sorted { $0.lastAt > $1.lastAt }
    }

    // MARK: - Day tiers

    /// The zone moved: `calendar` bins every day from now on. The bin cache forgets its
    /// day and every chat is re-binned (`rebinChats`), so `summary` finds a chat on the
    /// date a range asked in the new zone names (issue #13). The system's notice passes
    /// this actor's own calendar; a test passes a fixed one.
    func timeZoneDidChange(calendar: Calendar) {
        self.calendar = calendar
        dayBins.reset()
        rebinChats()
    }

    /// Every chat's days re-binned into this actor's calendar: the folded tier (`byDay`)
    /// re-keyed by `DayRekey.midpoint`, days landing on one key added together, and the
    /// recent tier rebuilt from `recentTurns`. A turn is in one tier, so nothing is
    /// counted twice or lost. Nothing here is persisted, so there is no cache to mark.
    func rebinChats() {
        guard !sessionAggs.isEmpty else { return }
        let calendar = self.calendar
        for (id, agg) in sessionAggs {
            var rekeyed: [Date: DaySlice] = [:]
            for (saved, slice) in agg.byDay {
                let key = DayRekey.midpoint(saved, calendar: calendar)
                var merged = rekeyed[key] ?? DaySlice()
                merged.turns += slice.turns
                merged.tokens += slice.tokens
                merged.mainTokens += slice.mainTokens
                rekeyed[key] = merged
            }
            sessionAggs[id]?.byDay = rekeyed
        }
        rebuildRecentByDay()
    }

    /// Every chat's recent tier rebuilt from `recentTurns` in this actor's calendar: the
    /// tier is a function of those turns and nothing else. Once over the turns, not
    /// once per chat.
    private func rebuildRecentByDay() {
        var byChat: [String: [Date: DaySlice]] = [:]
        for turn in recentTurns {
            let day = dayStart(for: turn.timestamp)
            var slice = byChat[turn.sessionID]?[day] ?? DaySlice()
            slice.turns += 1
            slice.tokens += turn.tokens
            if turn.agentID == nil { slice.mainTokens += turn.tokens }
            byChat[turn.sessionID, default: [:]][day] = slice
        }
        for id in Array(sessionAggs.keys) {
            sessionAggs[id]?.recentByDay = byChat[id] ?? [:]
        }
    }

    /// A turn leaving `recentTurns` moves its share of its day to its chat's folded tier.
    /// The session totals, model rows and agent took it when it was recorded.
    private func foldIntoChat(_ t: Turn) {
        guard var agg = sessionAggs[t.sessionID] else { return }
        let day = dayStart(for: t.timestamp)
        var slice = agg.byDay[day] ?? DaySlice()
        slice.turns += 1
        slice.tokens += t.tokens
        if t.agentID == nil { slice.mainTokens += t.tokens }
        agg.byDay[day] = slice
        sessionAggs[t.sessionID] = agg
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
        repriceIfTableChanged()
        reloadNamesIfChanged()
        scanAndIngest()
        pruneAndFold()
    }

    /// models.dev can answer after the first scan — the launch poll reads the logs while
    /// the fetch is still out — and a model the live table did not know yet was read at
    /// $0 (`turn`). When the table moves, every turn of the 31-day window is priced again
    /// from the tokens and the model it kept, which is what a relaunch would do. So is
    /// every chat lying wholly inside the window: all its turns are still here, and it is
    /// recorded again from them. Every other chat's recent days are rebuilt from the
    /// repriced turns, since the recent tier is a function of `recentTurns` (issue #13).
    /// A longer chat's folded days, its model and agent rows and its session totals, and
    /// Activity's folded days, keep the dollars they were read with — nothing finer than
    /// a day's or a chat's sum is left of them to price.
    private func repriceIfTableChanged() {
        let current = ModelPricing.generation
        guard pricedGeneration != current else { return }
        pricedGeneration = current
        for i in recentTurns.indices {
            let tokens = Self.priced(recentTurns[i].tokens, model: recentTurns[i].model)
            recentTurns[i].tokens = tokens
            recentTurns[i].cost = tokens.cost?.total ?? 0
        }
        // A chat that started inside the window has every turn in `recentTurns`, in the
        // order they were first recorded; recording them again rebuilds it exactly —
        // model rows, agents and session totals included.
        let windowStart = Date().addingTimeInterval(-recentWindow)
        let rebuilt = Set(sessionAggs.filter { $0.value.firstAt >= windowStart }.keys)
        for id in rebuilt { sessionAggs[id] = nil }
        for turn in recentTurns where rebuilt.contains(turn.sessionID) { record(turn, recent: true) }
        // Every chat's recent tier from the repriced turns, the longer chats' included:
        // otherwise their recent days would keep the old dollars until the next re-bin
        // or fold, and jump then.
        rebuildRecentByDay()
    }

    /// `tokens` with the dollars the live table gives `model` now: a per-bucket split
    /// when the table knows the model, none when it does not — $0 in the dollar column,
    /// the tokens kept. The one pricing rule for a turn read today and a turn re-priced.
    nonisolated static func priced(_ tokens: TokenBreakdown, model: String) -> TokenBreakdown {
        var bare = tokens
        bare.cost = nil
        guard let price = ModelPricing.dynamicLookup(for: model) else { return bare }
        return bare.priced(with: price)
    }

    /// Re-reads `session_index.jsonl` only when it has actually changed. Codex rewrites
    /// the whole file on every rename, so a poll that finds the same size and timestamp
    /// has nothing new to learn.
    private func reloadNamesIfChanged() {
        guard let indexURL else { return }
        // `FileManager`, not `URL.resourceValues`: a `URL` caches the resource values it
        // has already been asked for, and this one is a stored property, so the gate
        // would keep seeing the timestamp of the first poll for the life of the process.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: indexURL.path),
              let mtime = attributes[.modificationDate] as? Date else {
            names = [:]
            indexMark = nil
            return
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let mark = indexMark, mark.size == size, mark.mtime == mtime { return }
        indexMark = (size, mtime)
        names = Self.parseIndex(try? Data(contentsOf: indexURL))
    }

    /// `{"id","thread_name","updated_at"}`, several lines per id — Codex renames a
    /// thread seconds after opening it — so the latest `updated_at` wins and a tie goes
    /// to the later line. A line we cannot read is skipped, not fatal: the index is a
    /// convenience and the first prompt is still there.
    nonisolated static func parseIndex(_ data: Data?) -> [String: String] {
        guard let data, !data.isEmpty else { return [:] }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        var best: [String: (name: String, at: Date)] = [:]
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String,
                  !name.isEmpty else { continue }
            let stamp = obj["updated_at"] as? String
            let at = stamp.flatMap { fractional.date(from: $0) ?? plain.date(from: $0) }
                ?? .distantPast
            if let current = best[id], current.at > at { continue }
            best[id] = (name, at)
        }
        return best.mapValues(\.name)
    }

    /// A chat Codex never named is still recognisable by what it was asked to do.
    /// § Facts: the first user message whose `content_item_kinds` says `user.text`;
    /// failing that the first `input_text` that does not open with `<` or `#`, which is
    /// how the AGENTS.md and environment preambles arrive under the user role. A
    /// sub-agent's log opens with the task it was handed, which is not what the user
    /// typed, so those files are never asked.
    private func captureFirstPrompt(_ obj: [String: Any], state: inout FileState) {
        guard !state.sawPrompt, !state.isSubagent, let sessionID = state.sessionID else { return }
        guard let payload = obj["payload"] as? [String: Any],
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return }
        guard let raw = content.first(where: { $0["type"] as? String == "input_text" })?["text"] as? String
        else { return }

        let meta = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        let kinds = meta?["content_item_kinds"] as? [String]
        if let kinds {
            // A kinds list that is not `user.text` is machinery, whatever it looks like.
            guard kinds.contains("user.text") else { return }
        } else {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("<"), !trimmed.hasPrefix("#") else { return }
        }
        guard let title = Self.promptTitle(raw) else { return }

        // `.distantFuture` for a line we cannot date: it fills an empty slot and never
        // displaces a prompt that knows when it was typed.
        let at = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? .distantFuture
        state.sawPrompt = true
        if let existing = firstPrompts[sessionID], existing.at <= at { return }
        firstPrompts[sessionID] = (title, at)
    }

    /// Whitespace-collapsed and cut at 80 characters — the same shape § 2 gives
    /// Claude's first prompts, so a row is the same width whichever provider wrote it.
    nonisolated static func promptTitle(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 80 else { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }

    /// Codex's own name for the chat, or the first thing the user typed in it.
    private func title(for sessionID: String) -> String? {
        names[sessionID] ?? firstPrompts[sessionID]?.text
    }

    private func ingest(_ turns: [Turn]) {
        let recentCutoff = Date().addingTimeInterval(-recentWindow)
        for turn in turns {
            // Before the fold decision: the session aggregate reaches back 92 days,
            // three times further than `recentTurns`. Its day goes to the tier the turn
            // goes to.
            let recent = turn.timestamp >= recentCutoff
            record(turn, recent: recent)
            if recent {
                recentTurns.append(turn)
            } else {
                fold(turn)
            }
        }
    }

    /// Adds one turn to its chat's aggregate: the session totals, the local day in the
    /// tier the turn goes to (`recent`: into `recentTurns`), and — when it came from a
    /// sub-agent rollout — that agent's own row.
    private func record(_ t: Turn, recent: Bool) {
        var agg = sessionAggs[t.sessionID] ?? SessionAgg(
            projectSlug: t.projectSlug, origin: t.origin,
            firstAt: t.timestamp, lastAt: t.timestamp
        )
        agg.firstAt = min(agg.firstAt, t.timestamp)
        agg.lastAt = max(agg.lastAt, t.timestamp)
        agg.turns += 1
        agg.tokens += t.tokens

        // Before the main/agent branch, so a sub-agent's response counts towards the
        // chat's model rows. `t.model` and `t.effort` are already the answer of the
        // `turn_id` join: `recordTurn` resolves each `token_usage_record` against the
        // `turn_context` that opened its turn (else the file's latest), and the counter
        // path against the model the file had named when the delta was read.
        let effort = SessionModelSummary.effort(from: t.effort)
        let modelKey = SessionModelSummary.key(model: t.model, effort: effort)
        var model = agg.byModel[modelKey]
            ?? ModelAgg(model: t.model, effort: effort, turns: 0, tokens: .zero)
        model.turns += 1
        model.tokens += t.tokens
        agg.byModel[modelKey] = model

        let day = dayStart(for: t.timestamp)
        var slice = (recent ? agg.recentByDay[day] : agg.byDay[day]) ?? DaySlice()
        slice.turns += 1
        slice.tokens += t.tokens

        if let agentID = t.agentID {
            var a = agg.agents[agentID] ?? AgentAgg(
                kind: t.agentKind ?? "sub-agent", model: nil, effort: nil,
                firstAt: t.timestamp, lastAt: t.timestamp, turns: 0, tokens: .zero
            )
            if let kind = t.agentKind { a.kind = kind }
            a.firstAt = min(a.firstAt, t.timestamp)
            // "Last model seen" is the last one in time, not the last one parsed: two
            // rollouts of one session are read in whatever order the enumerator hands
            // them over.
            if t.timestamp >= a.lastAt {
                a.lastAt = t.timestamp
                a.model = t.model
                a.effort = t.effort
            }
            a.turns += 1
            a.tokens += t.tokens
            agg.agents[agentID] = a
        } else {
            agg.mainTokens += t.tokens
            slice.mainTokens += t.tokens
            // The chat's project and originator are the main thread's; a sub-agent's
            // only stand in until the parent's rollout has been read.
            if !agg.hasMainIdentity || t.timestamp >= agg.lastAt {
                agg.projectSlug = t.projectSlug
                agg.origin = t.origin ?? agg.origin
            }
            agg.hasMainIdentity = true
        }

        if recent { agg.recentByDay[day] = slice } else { agg.byDay[day] = slice }
        sessionAggs[t.sessionID] = agg
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

    /// Moves every turn older than `cutoff` out of `recentTurns`: into its day in
    /// `oldDays` and into its chat's folded tier (`byDay`). If anything moved, every
    /// chat's recent tier is rebuilt from the turns that are left, so each turn is in
    /// exactly one tier (issue #13). `pruneAndFold` calls this with
    /// `Date() − recentWindow`; a test calls it with a cutoff of its own, so a fold
    /// needs no wait.
    func foldTurns(olderThan cutoff: Date) {
        guard recentTurns.contains(where: { $0.timestamp < cutoff }) else { return }
        var kept: [Turn] = []
        kept.reserveCapacity(recentTurns.count)
        for t in recentTurns {
            if t.timestamp < cutoff {
                fold(t)
                foldIntoChat(t)
            } else {
                kept.append(t)
            }
        }
        recentTurns = kept
        rebuildRecentByDay()
    }

    private func pruneAndFold() {
        foldTurns(olderThan: Date().addingTimeInterval(-recentWindow))
        let dayCutoff = dayStart(for: Date().addingTimeInterval(-dayRetention))
        if oldDays.keys.contains(where: { $0 < dayCutoff }) {
            oldDays = oldDays.filter { $0.key >= dayCutoff }
        }
        let sessionCutoff = Date().addingTimeInterval(-sessionRetention)
        if sessionAggs.contains(where: { $0.value.lastAt < sessionCutoff }) {
            sessionAggs = sessionAggs.filter { $0.value.lastAt >= sessionCutoff }
            firstPrompts = firstPrompts.filter { sessionAggs[$0.key] != nil }
        }
    }

    private func dayStart(for date: Date) -> Date {
        dayBins.start(of: date, in: calendar)
    }

    // MARK: - File scanning

    private func scanAndIngest() {
        var seenKeys: Set<String> = []
        for directory in [rootURL, archivedURL].compactMap({ $0 }) {
            scan(directory, seenKeys: &seenKeys)
        }
        // Parse state for a rollout the enumerators no longer return — a deleted
        // session, a tree that aged out of the mtime window — would otherwise stay
        // pinned for the life of the process.
        if fileStates.count > seenKeys.count {
            fileStates = fileStates.filter { seenKeys.contains($0.key) }
        }
    }

    private func scan(_ directory: URL, seenKeys: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-mtimeWindow)
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            // Untouched for a year: too old to reach any figure we show, so it is
            // never parsed and — by staying out of `seenKeys` — never remembered.
            guard (values?.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            // The thread the file belongs to, not where it currently sits: archiving a
            // rollout moves it from the dated tree into `archived_sessions`, and a
            // path key would make the copy a brand-new file and bill it all over again.
            let key = Self.fileKey(for: url)
            seenKeys.insert(key)

            var state = fileStates[key] ?? FileState()
            if size < state.consumed {
                // Truncated or rewritten in place — the carried offset and counter
                // baseline are invalid, and the file is read again from the top. What it
                // has already billed stays billed (`restarted(after:)`).
                state = Self.restarted(after: state)
            }
            if size > state.consumed {
                // One file at a time inside an autorelease pool: a first scan over a
                // long-lived session tree is a lot of JSON garbage otherwise.
                autoreleasepool { parseTail(at: url, key: key, state: &state) }
            }
            fileStates[key] = state
        }
    }

    /// A fresh parse state for a file that shrank, carrying forward the two things that
    /// say what it has already billed: the responses it named (`seenResponses`), so a
    /// re-read record is not billed twice, and whether it bills from records at all
    /// (`sawRecord`), so the counters that restate those records bill nothing either.
    /// The offset, the counter baseline, the pending tokens, the contexts and the
    /// identity are read again from the file. A rollout that writes no records has no
    /// ids to remember: re-reading one still bills its counter deltas again — rare, and
    /// the one double count left.
    private static func restarted(after old: FileState) -> FileState {
        var state = FileState()
        state.seenResponses = old.seenResponses
        state.sawRecord = old.sawRecord
        return state
    }

    /// A rollout's identity: the thread uuid its file name ends with
    /// (`rollout-<timestamp>-<uuid>.jsonl`). Falls back to the path for anything that
    /// does not look like one, which is then keyed exactly as it used to be.
    nonisolated static func fileKey(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let tail = String(name.suffix(36))
        return isUUID(tail) ? tail : url.path
    }

    private nonisolated static func isUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return s.allSatisfy { $0 == "-" || $0.isHexDigit }
    }

    private func parseTail(at url: URL, key: String, state: inout FileState) {
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
                    if let turn = parseLine(line, state: &state, fallbackSlug: fallbackSlug, fileKey: key) {
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
    /// the turn a `token_count` delta completes, if any — or, at a `turn_context`, the
    /// turn that names deltas which arrived before the file had a model.
    private func parseLine(
        _ data: Data, state: inout FileState, fallbackSlug: String, fileKey: String
    ) -> Turn? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }

        if type == "session_meta" {
            // Only the FIRST meta is this file's identity: a sub-agent rollout's second
            // line is a verbatim copy of its parent's meta, and adopting it would hand
            // the agent's tokens to the main thread.
            guard !state.sawMeta, let payload = obj["payload"] as? [String: Any] else { return nil }
            state.sawMeta = true
            if let cwd = payload["cwd"] as? String {
                state.projectSlug = Self.encode(cwd: cwd)
            }
            state.sessionID = payload["session_id"] as? String
            state.threadID = payload["id"] as? String
            state.origin = payload["originator"] as? String
            if payload["thread_source"] as? String == "subagent" {
                state.isSubagent = true
                // `agent_nickname` is JSON null on a sub-agent that was never named, in
                // which case its path is what the user would recognise.
                state.agentKind = (payload["agent_nickname"] as? String)
                    ?? (payload["agent_path"] as? String)
            }
            return nil
        }

        if type == "turn_context" {
            if let payload = obj["payload"] as? [String: Any] {
                let ctx = TurnContext(
                    model: payload["model"] as? String,
                    effort: payload["effort"] as? String
                )
                if ctx.model != nil || ctx.effort != nil {
                    state.latestContext = ctx
                    if let turnID = payload["turn_id"] as? String { state.contexts[turnID] = ctx }
                }
                if let model = ctx.model { state.currentModel = model }
                if let effort = ctx.effort { state.currentEffort = effort }
                // `session_meta` names the cwd on line 1 of every rollout; this is the
                // fallback for a file whose first line we never saw.
                if state.projectSlug == nil, let cwd = payload["cwd"] as? String {
                    state.projectSlug = Self.encode(cwd: cwd)
                }
            }
            // Tokens spent before any model was named are billed here, at the first
            // `turn_context` that can price and label them — one extra turn, stamped
            // when they were actually spent.
            guard let pending = state.pendingTokens, let model = state.currentModel else { return nil }
            let ts = state.pendingSince ?? Date()
            state.pendingTokens = nil
            state.pendingSince = nil
            return turn(tokens: pending, model: model, effort: state.currentEffort,
                        at: ts, state: state, fallbackSlug: fallbackSlug, fileKey: fileKey)
        }

        // The authoritative per-response bill, when the file writes one. `compacted`
        // embeds a copy of the latest record under `payload.latest_token_usage_record`
        // and is deliberately not parsed at all: it is not a `token_usage_record` at
        // top level, so it falls through every branch here.
        if type == "token_usage_record" {
            return recordTurn(obj, state: &state, fallbackSlug: fallbackSlug, fileKey: fileKey)
        }

        if type == "response_item" {
            captureFirstPrompt(obj, state: &state)
            return nil
        }

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

        // The counter keeps tracking whatever the file writes — a file that switches to
        // records mid-way must not measure its next delta from a stale baseline — but
        // once a record has been seen, the record is the bill.
        if state.sawRecord { return nil }

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

        let cacheRead = max(0, delta.cached)
        let cacheWrite = max(0, delta.cacheWrite)
        let tokens = TokenBreakdown(
            // OpenAI's own formula: ordinary_input = input − cached − cache_write. All
            // three counters live inside `input_tokens`, so leaving the writes in would
            // bill them twice — once at the input rate, once at the write rate — and add
            // them to the turn's total a second time.
            input: max(0, delta.input - cacheRead - cacheWrite),
            output: max(0, delta.output),
            cacheRead: cacheRead,
            cacheWrite5m: cacheWrite,
            cacheWrite1h: 0,
            thinking: max(0, delta.reasoning)
        )
        let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()

        // Every real rollout writes `turn_context` before its first `token_count`; when
        // one doesn't, the tokens are real but nameless, so they wait in the file's state
        // for the first model that follows instead of being dropped. The baseline above
        // has already advanced either way — the next delta must not be billed from zero.
        guard let model = state.currentModel else {
            state.pendingTokens = state.pendingTokens.map { $0 + tokens } ?? tokens
            if state.pendingSince == nil { state.pendingSince = ts }
            return nil
        }

        return turn(tokens: tokens, model: model, effort: state.currentEffort,
                    at: ts, state: state, fallbackSlug: fallbackSlug, fileKey: fileKey)
    }

    /// One `token_usage_record`: the usage the API itself reported for one response.
    /// Unlike the cumulative counter it covers compaction calls, which is the spend
    /// `token_count` silently omits.
    private func recordTurn(
        _ obj: [String: Any], state: inout FileState, fallbackSlug: String, fileKey: String
    ) -> Turn? {
        guard let payload = obj["payload"] as? [String: Any],
              let usage = payload["usage"] as? [String: Any] else { return nil }
        // Set before the dedupe returns: a file that writes records bills from records
        // even when this particular line is one it has already seen.
        state.sawRecord = true

        let responseID = (payload["response_id"] as? String) ?? ""
        if !responseID.isEmpty {
            let threadID = (payload["thread_id"] as? String) ?? ""
            guard state.seenResponses
                .insert(Self.stableHash("\(threadID)|\(responseID)")).inserted
            else { return nil }
        }

        let input = Self.intValue(usage["input_tokens"])
        let cacheRead = max(0, Self.intValue(usage["cached_input_tokens"]))
        let cacheWrite = max(0, Self.intValue(usage["cache_write_input_tokens"]))
        let output = max(0, Self.intValue(usage["output_tokens"]))
        let reasoning = max(0, Self.intValue(usage["reasoning_output_tokens"]))
        guard input > 0 || output > 0 else { return nil }

        // OpenAI's own formula: ordinary_input = input − cached − cache_write. All
        // three counters live inside `input_tokens`, so leaving the writes in would
        // bill them twice and add them to the turn's total a second time.
        let tokens = TokenBreakdown(
            input: max(0, input - cacheRead - cacheWrite),
            output: output,
            cacheRead: cacheRead,
            cacheWrite5m: cacheWrite,
            cacheWrite1h: 0,
            thinking: reasoning
        )
        let ts = (obj["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()
        let ctx = Self.context(
            forTurn: payload["turn_id"] as? String, in: state.contexts, latest: state.latestContext
        )
        guard let model = ctx?.model ?? state.currentModel else {
            // Same recovery as the counter path: real tokens with nothing to price them
            // wait for the first `turn_context` that follows.
            state.pendingTokens = state.pendingTokens.map { $0 + tokens } ?? tokens
            if state.pendingSince == nil { state.pendingSince = ts }
            return nil
        }
        return turn(tokens: tokens, model: model, effort: ctx?.effort ?? state.currentEffort,
                    at: ts, state: state, fallbackSlug: fallbackSlug, fileKey: fileKey)
    }

    /// The `turn_context` a record belongs to: the one that opened its `turn_id`, and
    /// failing that the latest the file has seen.
    nonisolated static func context(
        forTurn turnID: String?, in contexts: [String: TurnContext], latest: TurnContext?
    ) -> TurnContext? {
        if let turnID, let exact = contexts[turnID] { return exact }
        return latest
    }

    /// FNV-1a over UTF-8: 8 bytes per remembered response instead of a retained pair of
    /// id strings, and stable for the life of the file's parse state.
    nonisolated static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// Prices one delta and dresses it as a turn. A model models.dev doesn't know keeps
    /// its tokens with no dollar split (`cost` stays nil): $0 is the honest answer for
    /// the dollar column, and dropping the turn and its tokens with it would not be.
    private func turn(
        tokens: TokenBreakdown,
        model: String,
        effort: String?,
        at timestamp: Date,
        state: FileState,
        fallbackSlug: String,
        fileKey: String
    ) -> Turn {
        let tokens = Self.priced(tokens, model: model)
        // A rollout whose first line we never read still has an identity: the thread
        // uuid its file name ends with, which is exactly what the meta would have said.
        let threadID = state.threadID ?? fileKey
        return Turn(
            timestamp: timestamp,
            model: model,
            effort: effort,
            projectSlug: state.projectSlug ?? fallbackSlug,
            cost: tokens.cost?.total ?? 0,
            tokens: tokens,
            sessionID: state.sessionID ?? threadID,
            threadID: threadID,
            agentID: state.isSubagent ? threadID : nil,
            agentKind: state.isSubagent ? (state.agentKind ?? "sub-agent") : nil,
            origin: state.origin
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
