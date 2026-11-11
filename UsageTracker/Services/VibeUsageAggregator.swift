import Foundation

/// Local usage for Mistral's vibe CLI (spec 2026-11-10 Mistral provider § Local usage (P2)): the
/// same `CLIBreakdown` and `WindowUsage` the other CLIs' aggregators produce, so every cost view
/// renders it under the Mistral tab.
///
/// vibe keeps no timed per-call log. It keeps a cumulative `tokenUsage` per session, timed at
/// every step (`VibeSessionStore`), and `VibeLedger.attribute` gives what rises above each
/// session's high-water mark to the moment that shows it: a session that crosses midnight splits
/// between the days. vibe prunes a long session's early journal segments, so what has been
/// attributed is kept in `vibe-usage-ledger-v1.json` beside the Claude cost cache: a pruned
/// segment never moves tokens already counted, and a relaunch finds each day where it was. A
/// session directory whose files have not moved is not read again, and reads within
/// `minimumReadInterval` share one.
///
/// Every session directory counts, the fleet's own runs included (Decision 1). Dollars are
/// models.dev's list price for the session's model (`MistralModelPricing`), worked out when
/// asked, so a table that learns a model later prices the past as well. They are an
/// API-list-price equivalent of the local tokens, always (`CostCopy.alwaysAPIEquivalent`), never
/// Mistral's own count of the allowance, and nothing adds the two. Every count saturates.
actor VibeUsageAggregator: CostLogAggregating {
    static let shared = VibeUsageAggregator()

    /// `~/Library/Application Support/UsageTracker/vibe-usage-ledger-v1.json`. Not private: the
    /// default argument of `init`.
    static var defaultLedgerURL: URL {
        AgentPaths.appSupportURL.appendingPathComponent("vibe-usage-ledger-v1.json")
    }

    /// The model of a session with no `meta.json`: counted, unpriced, and left out of the
    /// per-model rows (`ModelPricing.isSynthetic`).
    static let unknownModel = "unknown"

    /// Reads closer together than this share one read (plan R9): the provider's poll, the status
    /// file's gather and an open Dashboard ask within seconds of each other, and a session vibe
    /// is writing changes between them, so each would read its whole journal again.
    static let minimumReadInterval: TimeInterval = 20

    private let rootURL: URL
    private let ledgerURL: URL?
    /// The calendar "today" and the daily rows are taken in. Injected so a test pins a zone.
    private let calendar: Calendar
    private var ledger = VibeLedger()
    private var loaded = false
    private var lastReadAt: Date?
    /// Sessions skipped for their store format, by the mark they had then: logged once, and read
    /// again only when they change.
    private var skipped: [String: VibeSessionStore.Mark] = [:]
    /// How many sessions the last read skipped for their store format (spec § Unknown store).
    private(set) var lastSkippedCount = 0

    /// `~/.vibe` only: a `VIBE_HOME` set in a shell is invisible to an app started from the Dock
    /// (spec § Local usage (P2), Decisions). A nil `ledgerURL` keeps nothing on disk.
    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe/logs/session/unified", isDirectory: true),
        ledgerURL: URL? = VibeUsageAggregator.defaultLedgerURL,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.rootURL = rootURL
        self.ledgerURL = ledgerURL
        self.calendar = calendar
    }

    // MARK: - Reading

    func refresh() async {
        refresh(now: Date())
    }

    /// Reads each session directory whose files moved since it was last read, once, and lets
    /// that one read feed the steps, the meta and the last activity; tidies the ledger and saves
    /// it when anything changed. Within `minimumReadInterval` of the last read it reads nothing.
    /// A directory untouched for a year holds nothing any figure reaches back to and is not opened.
    func refresh(now: Date) {
        if let last = lastReadAt, now >= last, now.timeIntervalSince(last) < Self.minimumReadInterval { return }
        lastReadAt = now
        loadLedgerOnce()
        var changed = false
        var skippedNow = 0
        let oldest = now.addingTimeInterval(-VibeLedger.dayRetention)
        for directory in VibeSessionStore.children(of: rootURL) {
            let id = directory.lastPathComponent
            guard let mark = VibeSessionStore.mark(of: directory), mark.newest >= oldest else { continue }
            if ledger.sessions[id]?.mark == mark || skipped[id] == mark { continue }
            switch VibeSessionStore.read(directory) {
            case .unknownStore:
                skipped[id] = mark
                skippedNow += 1
            case .session(let meta, let points):
                var session = ledger.sessions[id] ?? VibeLedger.Session()
                let attributed = VibeLedger.attribute(points, after: session.counted)
                session.steps += attributed.steps
                session.counted = attributed.counted
                if let newest = points.last?.at {
                    session.lastPointAt = max(session.lastPointAt ?? newest, newest)
                }
                session.meta = meta
                session.mark = mark
                ledger.sessions[id] = session
                changed = true
            }
        }
        lastSkippedCount = skippedNow
        if skippedNow > 0 {
            NSLog("[UT] vibe: %d session(s) skipped, store format is not %@", skippedNow, VibeSessionStore.storeFormat)
        }
        let tidied = ledger.tidied(now: now, calendar: calendar)
        if tidied != ledger {
            ledger = tidied
            changed = true
        }
        if changed { saveLedger() }
    }

    /// `refresh(now:)`, then the week's dollars: the provider's one question per poll.
    func refreshedWeekCost(now: Date) -> Double {
        refresh(now: now)
        return weekCost(now: now)
    }

    /// The ledger on disk, once per process, if it is this rule's (`VibeLedger.currentVersion`);
    /// any other — older, unknown, unreadable — is left to be rebuilt from the logs.
    private func loadLedgerOnce() {
        guard !loaded else { return }
        loaded = true
        guard let ledgerURL,
              let data = try? Data(contentsOf: ledgerURL),
              let saved = try? JSONDecoder().decode(VibeLedger.self, from: data),
              saved.version == VibeLedger.currentVersion
        else { return }
        ledger = saved
    }

    private func saveLedger() {
        guard let ledgerURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: [.atomic])
        } catch {
            NSLog("[UT] vibe ledger write failed: %@", String(describing: error))
        }
    }

    // MARK: - Figures

    func weekCost(now: Date) -> Double {
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        return slices().reduce(0) { $1.at >= weekAgo ? $0 + $1.cost : $0 }
    }

    func breakdown() -> CLIBreakdown {
        breakdown(now: Date())
    }

    /// `breakdown()` as of `now`: today is `now`'s day in this aggregator's calendar, the one the
    /// daily rows are binned in.
    func breakdown(now: Date) -> CLIBreakdown {
        let startOfDay = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        var todayCost = 0.0
        var todayTokens = 0
        var todayBreakdown = TokenBreakdown.zero
        var todayTurns = 0
        var weekCost = 0.0
        var monthCost = 0.0
        var byModelToday: [String: ModelAcc] = [:]
        var days: [Date: DayAcc] = [:]
        var projectsWeek: [String: ProjectAcc] = [:]
        var projectsMonth: [String: ProjectAcc] = [:]

        for slice in slices() {
            if slice.at >= startOfDay {
                todayCost += slice.cost
                todayTokens = TokenBreakdown.saturating(todayTokens, slice.tokens.total)
                todayBreakdown += slice.tokens
                todayTurns = TokenBreakdown.saturating(todayTurns, slice.turns)
                if let name = ModelPricing.displayName(for: slice.model) {
                    byModelToday[name, default: ModelAcc()].add(slice)
                }
            }
            if slice.at >= weekAgo {
                weekCost += slice.cost
                projectsWeek[slice.projectSlug, default: ProjectAcc(lastActivity: slice.at)].add(slice)
            }
            if slice.at >= monthAgo {
                monthCost += slice.cost
                projectsMonth[slice.projectSlug, default: ProjectAcc(lastActivity: slice.at)].add(slice)
            }
            days[calendar.startOfDay(for: slice.at), default: DayAcc()].add(slice)
        }

        let daily = days.map { day, acc in
            CLIDailySummary(
                day: day, totalCost: acc.cost, totalTokens: acc.tokens, tokens: acc.breakdown,
                turns: acc.turns, byFamily: acc.byFamily
            )
        }.sorted { $0.day < $1.day }

        return CLIBreakdown(
            todayCost: todayCost,
            todayTokens: todayTokens,
            todayTokenBreakdown: todayBreakdown,
            todayTurns: todayTurns,
            weekCost: weekCost,
            monthCost: monthCost,
            byModelToday: Self.models(byModelToday),
            daily: daily,
            projectsWeek: Self.summaries(projectsWeek),
            projectsMonth: Self.summaries(projectsMonth),
            updatedAt: now
        )
    }

    func usage(from start: Date, to end: Date) -> WindowUsage {
        var cost = 0.0
        var tokens = 0
        // Not `breakdown`: a local of that name would shadow the `breakdown()` method.
        var windowBreakdown = TokenBreakdown.zero
        var turns = 0
        var projects: [String: ProjectAcc] = [:]
        var byModel: [String: ModelAcc] = [:]
        for slice in slices() where slice.at >= start && slice.at <= end {
            cost += slice.cost
            tokens = TokenBreakdown.saturating(tokens, slice.tokens.total)
            windowBreakdown += slice.tokens
            turns = TokenBreakdown.saturating(turns, slice.turns)
            projects[slice.projectSlug, default: ProjectAcc(lastActivity: slice.at)].add(slice)
            if let name = ModelPricing.displayName(for: slice.model) {
                byModel[name, default: ModelAcc()].add(slice)
            }
        }
        return WindowUsage(
            start: start, end: end, cost: cost, tokens: tokens, breakdown: windowBreakdown,
            turns: turns, projects: Self.summaries(projects), models: Self.models(byModel)
        )
    }

    // MARK: - Steps as the figures read them

    /// One step: when, where, on what model, its tokens priced now.
    private struct Slice {
        let at: Date
        let projectSlug: String
        let model: String
        let tokens: TokenBreakdown
        let turns: Int

        var cost: Double { tokens.cost?.total ?? 0 }
    }

    private func slices() -> [Slice] {
        var out: [Slice] = []
        for session in ledger.sessions.values {
            let rate = Self.price(for: session.meta)
            let modelID = Self.model(of: session.meta)
            let slug = Self.projectSlug(session.meta.workingDirectory)
            for step in session.steps {
                out.append(Slice(
                    at: step.at, projectSlug: slug, model: modelID,
                    tokens: Self.tokens(of: step, price: rate), turns: step.turns
                ))
            }
        }
        return out
    }

    private struct ModelAcc {
        var cost = 0.0
        var tokens = 0
        var breakdown = TokenBreakdown.zero

        mutating func add(_ slice: Slice) {
            cost += slice.cost
            tokens = TokenBreakdown.saturating(tokens, slice.tokens.total)
            breakdown += slice.tokens
        }
    }

    private struct DayAcc {
        var cost = 0.0
        var tokens = 0
        var breakdown = TokenBreakdown.zero
        var turns = 0
        var byFamily: [String: Double] = [:]

        mutating func add(_ slice: Slice) {
            cost += slice.cost
            tokens = TokenBreakdown.saturating(tokens, slice.tokens.total)
            breakdown += slice.tokens
            turns = TokenBreakdown.saturating(turns, slice.turns)
            byFamily[ModelPricing.family(for: slice.model), default: 0] += slice.cost
        }
    }

    private struct ProjectAcc {
        var cost = 0.0
        var tokens = 0
        var turns = 0
        var lastActivity: Date

        mutating func add(_ slice: Slice) {
            cost += slice.cost
            tokens = TokenBreakdown.saturating(tokens, slice.tokens.total)
            turns = TokenBreakdown.saturating(turns, slice.turns)
            lastActivity = max(lastActivity, slice.at)
        }
    }

    private static func models(
        _ acc: [String: ModelAcc]
    ) -> [(model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)] {
        acc.map { (model: $0.key, cost: $0.value.cost, tokens: $0.value.tokens, breakdown: $0.value.breakdown) }
            .sorted { $0.cost == $1.cost ? $0.model < $1.model : $0.cost > $1.cost }
    }

    private static func summaries(_ acc: [String: ProjectAcc]) -> [ProjectSummary] {
        acc.map { slug, project in
            ProjectSummary(
                slug: slug,
                displayName: ProjectName.decode(encodedPath: slug),
                totalCost: project.cost,
                totalTokens: project.tokens,
                turns: project.turns,
                lastActivity: project.lastActivity
            )
        }
        .sorted { $0.totalCost == $1.totalCost ? $0.slug < $1.slug : $0.totalCost > $1.totalCost }
    }

    // MARK: - Chats

    /// Every vibe session with a step on a day of `[start, end]`, newest first (spec § Sessions).
    /// Spelled `async`, as `CodexUsageAggregator`'s is: a synchronous method would only overload
    /// the protocol's default, and a call through `CostLogAggregating` would answer `[]`.
    func sessions(from start: Date, to end: Date) async -> [SessionSummary] {
        ledger.sessions
            .compactMap { id, session in
                Self.summary(id: id, session: session, from: start, to: end, calendar: calendar)
            }
            .sorted { $0.lastAt == $1.lastAt ? $0.id < $1.id : $0.lastAt > $1.lastAt }
    }

    /// One session as History, `status.json` and `get_sessions` list it: its days inside the
    /// range, re-summed, as Codex's chats are clipped; its span its own (`firstAt` its first step,
    /// `lastAt` its newest point, a repeat included); one model row for the whole chat, never
    /// clipped. No sub-agents and no origin: a vibe child session is a directory of its own. nil
    /// when no step falls on a day of the range, which a session with no total never has.
    nonisolated static func summary(
        id: String, session: VibeLedger.Session, from start: Date, to end: Date, calendar: Calendar
    ) -> SessionSummary? {
        guard let firstAt = session.steps.map(\.at).min(),
              let lastStepAt = session.steps.map(\.at).max()
        else { return nil }
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.startOfDay(for: end)
        let rate = Self.price(for: session.meta)
        var byDay: [Date: SessionDaySummary] = [:]
        var wholeTokens = TokenBreakdown.zero
        var wholeTurns = 0
        for step in session.steps {
            let stepTokens = Self.tokens(of: step, price: rate)
            wholeTokens += stepTokens
            wholeTurns = TokenBreakdown.saturating(wholeTurns, step.turns)
            let day = calendar.startOfDay(for: step.at)
            guard day >= lower, day <= upper else { continue }
            let earlier = byDay[day]
            byDay[day] = SessionDaySummary(
                day: day,
                turns: TokenBreakdown.saturating(earlier?.turns ?? 0, step.turns),
                tokens: (earlier?.tokens ?? .zero) + stepTokens
            )
        }
        guard !byDay.isEmpty else { return nil }
        let days = byDay.values.sorted { $0.day < $1.day }
        let chatTokens = days.reduce(TokenBreakdown.zero) { $0 + $1.tokens }
        return SessionSummary(
            id: id,
            providerID: MistralProvider.serviceID,
            title: SessionTitle.clean(session.meta.title),
            projectSlug: Self.projectSlug(session.meta.workingDirectory),
            origin: nil,
            firstAt: firstAt,
            lastAt: max(lastStepAt, session.lastPointAt ?? lastStepAt),
            turns: days.reduce(0) { TokenBreakdown.saturating($0, $1.turns) },
            tokens: chatTokens,
            mainTokens: chatTokens,
            agents: [],
            days: days,
            models: [SessionModelSummary(
                model: Self.model(of: session.meta), effort: nil, turns: wholeTurns, tokens: wholeTokens
            )]
        )
    }

    // MARK: - Pricing and naming (pure)

    /// Spec § Token shape: fresh input (vibe's input less its cached part), cached, output, each
    /// at least zero. No cache-write and no reasoning figure exist at session level. Priced per
    /// kind when the session's model has a rate; tokens alone otherwise.
    nonisolated static func tokens(of step: VibeLedger.Step, price: ModelPrice?) -> TokenBreakdown {
        let cached = max(0, step.cached)
        let bare = TokenBreakdown(
            input: VibeLedger.rise(step.input, over: cached), output: max(0, step.output), cacheRead: cached
        )
        guard let price else { return bare }
        return bare.priced(with: price)
    }

    /// The session's rate from models.dev's `mistral` family (plan R5): `active_model`, then the
    /// id vibe sent, as keys, then by name, then by shorter line. nil: tokens without dollars
    /// (Decision 2).
    nonisolated static func price(for meta: VibeSessionStore.Meta) -> ModelPrice? {
        MistralModelPricing.price(activeModel: meta.activeModel, modelName: meta.modelName)
    }

    /// The session's model as every row names it: vibe's `active_model`, else the id it sent.
    nonisolated static func model(of meta: VibeSessionStore.Meta) -> String {
        meta.activeModel ?? meta.modelName ?? Self.unknownModel
    }

    /// The working directory percent-encoded as Codex's and Grok's slugs are, so
    /// `ProjectName.decode(encodedPath:)` reads it back exactly. Empty when meta has none.
    nonisolated static func projectSlug(_ workingDirectory: String?) -> String {
        guard let path = workingDirectory, !path.isEmpty else { return "" }
        return path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }
}
