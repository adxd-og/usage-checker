import Foundation

/// The Limits tab's decisions: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab and § Accounts without percent windows. What a load answered, which page the
/// selected provider gets, which windows the switch offers, which rows the list draws.
/// Pure: the view hands in the live snapshot, the settings and what `DashboardState`
/// published. Each `extension` below is one part of the page; the words are `LimitsCopy`'s.
enum LimitsRules {}

/// What one load of the Limits tab is for, and what it answered: the provider, the window
/// kind asked for, and what the shares are measured against. Two loads with the same query
/// show the same window or period against the same budget or limit; the later one only
/// has newer turns and a newer percent.
struct LimitsQuery: Hashable, Sendable {
    let serviceID: String
    let kind: BucketKind
    /// nil when the account has nothing to measure for `kind`: no mode, or no open window.
    let measure: LimitsMeasure?
    /// The period picked (spec 2026-10-16 limit analytics § The tab, item 1): the current
    /// one unless a past window or an earlier week is on screen.
    var period: LimitsPeriod = .current
}

/// Which window or period a share covers, and against what (§ Accounts without percent
/// windows, the mode table). What moves with every poll is left out: the period's end,
/// the live percent, a spend limit's used credits. The next ingest brings those.
enum LimitsMeasure: Hashable, Sendable {
    /// A subscription window, by its start to the minute. A reset starts another.
    case window(start: Date)
    /// Pay as you go's rolling 7 days, against the weekly budget when one is set.
    case payAsYouGo(budget: Double?)
    /// A spend limit's calendar month, against its limit.
    case spendLimit(monthStart: Date, limit: Double)
}

// MARK: - The query

extension LimitsRules {
    /// `date` to the nearest whole minute. A window is known by its start to the minute,
    /// so a reset a provider reports a second either way is the same window.
    nonisolated static func toMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    /// The query `request` answers for `period`: what `DashboardState` publishes with each
    /// load. With no request there is nothing to measure.
    nonisolated static func query(
        serviceID: String, kind: BucketKind, request: LimitShareRequest?, period: LimitsPeriod = .current
    ) -> LimitsQuery {
        guard let request else { return LimitsQuery(serviceID: serviceID, kind: kind, measure: nil, period: period) }
        let measure: LimitsMeasure
        switch request.mode {
        case .subscription:
            measure = .window(start: toMinute(request.period.start))
        case .payAsYouGo(let budget):
            measure = .payAsYouGo(budget: budget)
        case .spendLimit(let limit, _):
            measure = .spendLimit(monthStart: request.period.start, limit: limit)
        }
        return LimitsQuery(serviceID: serviceID, kind: kind, measure: measure, period: period)
    }

    /// The query the live snapshot and settings ask for now, for the period picked: the
    /// request `DashboardState.refreshLimitShare(kind:period:)` would make
    /// (`request(for:kind:period:…)`).
    nonisolated static func query(
        serviceID: String,
        service: ServiceSnapshot?,
        kind: BucketKind,
        period: LimitsPeriod = .current,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar
    ) -> LimitsQuery {
        let request = service.flatMap {
            LimitsRules.request(
                for: $0, kind: kind, period: period, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
            )
        }
        return query(serviceID: serviceID, kind: kind, request: request, period: period)
    }
}

extension DashboardState.LimitShareLoad {
    /// The query this load answered, its period included.
    var query: LimitsQuery {
        LimitsRules.query(serviceID: serviceID, kind: kind, request: request, period: period)
    }
}

extension LimitsRules {
    /// What a finished `DashboardState.refreshLimitShare(kind:)` publishes: the load when
    /// there is a share, and always the query it answered. No request means nothing to
    /// measure; a request with no share is pay as you go with no budget and nothing spent,
    /// which the page reads as "Nothing spent" from this answer.
    nonisolated static func published(
        serviceID: String,
        kind: BucketKind,
        request: LimitShareRequest?,
        share: LimitShare?,
        period: LimitsPeriod = .current,
        stretches: [String: [ChatStretch]] = [:],
        change: LimitChangeSignal? = nil
    ) -> (load: DashboardState.LimitShareLoad?, answer: LimitsQuery) {
        let load = request.flatMap { request in
            share.map {
                DashboardState.LimitShareLoad(
                    serviceID: serviceID, kind: kind, request: request, share: $0,
                    period: period, stretches: stretches, change: change
                )
            }
        }
        return (load, query(serviceID: serviceID, kind: kind, request: request, period: period))
    }
}

/// What the tab's `.task(id:)` watches: the query the live snapshot and settings ask, and
/// the cost log's ingest stamp (`CLIBreakdown.updatedAt`, new on every `refreshCLI()`). A
/// new query (a reset, a mode change, a new budget) loads at once; a new stamp loads the
/// same query again, when the turns and the live percent have moved.
struct LimitsLoadKey: Hashable, Sendable {
    let query: LimitsQuery
    /// nil until `refreshCLI()` has ingested the selected provider's log. A provider
    /// switch clears it.
    let ingestedAt: Date?
}

/// How long the window on screen is, in the words its strings use. Codex gives every
/// window over a day the kind `.weekly` (`CodexProvider.kind(for:)`), and the free plan's
/// is about 30 days: a month, not a week.
enum LimitsSpan: Equatable, Sendable {
    case session, week, month
}

/// What the Limits tab shows for the selected provider and window.
enum LimitsPage: Equatable, Sendable {
    /// Grok and Antigravity: no cost log that names a chat.
    case unsupported
    /// Claude or Codex reporting no window, budget or spend limit: signed out, or not
    /// polled yet.
    case nothingToMeasure
    /// A subscription whose window of this span has not opened.
    case noOpenWindow(LimitsSpan)
    /// No share has answered the query on screen yet.
    case loading
    /// Pay as you go with no budget and nothing spent in the period: nothing to divide by.
    case noSpend
    case ready(DashboardState.LimitShareLoad)
}

// MARK: - The page

extension LimitsRules {
    /// The longest window that is still a week: Codex labels anything longer "Monthly"
    /// (`CodexProvider.label(for:)`), a day's slack over seven.
    static let longestWeek: TimeInterval = 8 * 24 * 3600

    /// The span of the account's window of `kind`: a session, a week, or a month for a
    /// weekly-kind window longer than `longestWeek`. With no such window to read, the
    /// kind alone decides.
    nonisolated static func span(of kind: BucketKind, in service: ServiceSnapshot?) -> LimitsSpan {
        guard kind != .session else { return .session }
        guard let service,
              let length = LimitShareRules.coreBucket(kind: kind, in: service)?.windowDuration,
              length > longestWeek
        else { return .week }
        return .month
    }

    /// The page for the selected provider and window kind:
    /// 1. a provider whose log names no chat gets the empty state (§ The tab);
    /// 2. an account with no mode has nothing to measure (`LimitShareRules.mode`);
    /// 3. a subscription needs its window of `kind` open now, unless a past window is
    ///    picked;
    /// 4. a share is shown when it answered the query asked now (`query(serviceID:service:…)`):
    ///    same provider, kind, window or period, and budget or limit. A share of last week,
    ///    or against the budget set before, is not;
    /// 5. otherwise the load is running, except for pay as you go once the dashboard has
    ///    answered this very query with no share: no budget and no spend.
    ///
    /// `answered` is `DashboardState.limitShareAnswer`. A subscription's load always answers
    /// with a share, so it never reads as nothing spent.
    nonisolated static func page(
        serviceID: String,
        kind: BucketKind,
        period: LimitsPeriod = .current,
        service: ServiceSnapshot?,
        weeklyBudgetUSD: Double,
        load: DashboardState.LimitShareLoad?,
        answered: LimitsQuery?,
        now: Date,
        calendar: Calendar
    ) -> LimitsPage {
        guard DashboardState.hasSessionLog(for: serviceID) else { return .unsupported }
        guard let service, let mode = LimitShareRules.mode(of: service, weeklyBudgetUSD: weeklyBudgetUSD)
        else { return .nothingToMeasure }
        if mode == .subscription, period == .current {
            guard let bucket = LimitShareRules.coreBucket(kind: kind, in: service),
                  LimitShareRules.currentWindow(of: bucket, now: now) != nil
            else { return .noOpenWindow(span(of: kind, in: service)) }
        }
        let current = query(
            serviceID: serviceID, service: service, kind: kind, period: period,
            weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
        )
        if let load, load.query == current { return .ready(load) }
        if case .payAsYouGo = mode, answered == current { return .noSpend }
        return .loading
    }

    /// Whether the tab asks `DashboardState.refreshLimitShare(kind:)` for `key`: once the
    /// provider's cost log is in, and only for a provider whose log names a chat.
    nonisolated static func loads(_ key: LimitsLoadKey) -> Bool {
        key.ingestedAt != nil && DashboardState.hasSessionLog(for: key.query.serviceID)
    }
}

// MARK: - Window switch

extension LimitsRules {
    /// The `UserDefaults` key the window switch keeps its choice under, as a `BucketKind`
    /// raw value.
    static let windowKey = "limitsWindow"

    /// The windows the switch offers: the account's own, Session before Week
    /// (`LimitShareRules.windowKinds`); Codex Prolite has its Week alone. None for a
    /// provider the tab cannot measure, nor for an account with no window (pay as you go,
    /// a spend limit).
    nonisolated static func switchKinds(serviceID: String, service: ServiceSnapshot?) -> [BucketKind] {
        guard DashboardState.hasSessionLog(for: serviceID), let service else { return [] }
        return LimitShareRules.windowKinds(of: service)
    }

    /// The window on screen: the stored one while the account has it, else the week (the
    /// mockup's default), else the one window the account has. With no window at all the
    /// week stands in: the spend modes ignore the kind.
    nonisolated static func selectedKind(stored: String, offered: [BucketKind]) -> BucketKind {
        if let kind = BucketKind(rawValue: stored), offered.contains(kind) { return kind }
        if offered.isEmpty || offered.contains(.weekly) { return .weekly }
        return offered[0]
    }
}

// MARK: - The first card

extension LimitsRules {
    /// Where the budget link opens Settings: the weekly budget is on Advanced.
    static let budgetSettingsTab: SettingsTab = .advanced
}

// MARK: - The ranked list

/// One line of the ranked list: a chat or a project, or Earlier this month or Outside
/// this Mac under them. Every string is built here; `LimitsRankedCard` lays them out.
struct LimitsRow: Equatable, Identifiable, Sendable {
    /// The chat id or the project slug; "earlier" and "outside" for the rows under them.
    let id: String
    let title: String
    /// A chat's project, a project's chat count, or what Earlier or Outside stands for.
    let subtitle: String
    let share: String
    /// Empty for Outside this Mac, which has no local dollars.
    let dollars: String
}

/// The ranked list as drawn: the rows on screen, formatted, and how many the share ranks
/// in all ("Show all (2,000)").
struct LimitsRankedRows: Equatable, Sendable {
    let rows: [LimitsRow]
    let total: Int
}

extension LimitsRules {
    /// The rows the list shows before "Show all" (§ The tab, item 3).
    static let rowCap = 8

    /// The window's chats in the share's own ranking (points, then dollars), the first
    /// `rowCap` of them unless all are asked for. Only those are formatted. The project is
    /// named by `projectName`, the provider's own decoder (`SessionCopy.projectName`, which
    /// reads the disk for Claude). A chat with no name reads as History's does, its project
    /// and a day: here the day of its last turn in the window.
    nonisolated static func chatRows(
        of share: LimitShare,
        serviceID: String,
        showsAll: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current,
        projectName: (_ providerID: String, _ slug: String) -> String = SessionCopy.projectName(providerID:projectSlug:)
    ) -> LimitsRankedRows {
        let shown = showsAll ? share.chats[...] : share.chats.prefix(rowCap)
        let rows = shown.map { chat in
            let project = projectName(serviceID, chat.projectSlug)
            return LimitsRow(
                id: chat.id,
                title: SessionCopy.rowTitle(
                    title: chat.title, project: project, firstAt: chat.lastAt,
                    calendar: calendar, locale: locale
                ),
                subtitle: project,
                share: LimitsCopy.share(chat.points),
                dollars: LimitsCopy.dollars(chat.cost)
            )
        }
        return LimitsRankedRows(rows: rows, total: share.chats.count)
    }

    /// Whether the list has more rows than it shows capped.
    nonisolated static func canShowAll(count: Int) -> Bool {
        count > rowCap
    }
}

extension LimitsRules {
    /// The rows under the ranked ones, in order:
    /// - Earlier this month: a spend limit's local dollars from before the 31-day turn
    ///   horizon, one row, not split by chat;
    /// - Outside this Mac, when above 0, with no local dollars. On a Claude subscription
    ///   it is whole points: whole half hours of whole-number percents. So there it is
    ///   drawn only from one whole point; a smaller figure is residue and would read
    ///   "≈ 0 %". A spend limit's Outside is dollars over the limit and keeps its decimal.
    nonisolated static func tailRows(of share: LimitShare, mode: LimitMode, serviceID: String) -> [LimitsRow] {
        var rows: [LimitsRow] = []
        if let earlier = share.earlier {
            rows.append(LimitsRow(
                id: "earlier",
                title: LimitsCopy.earlierTitle,
                subtitle: LimitsCopy.earlierSubtitle,
                share: LimitsCopy.share(earlier.points),
                dollars: LimitsCopy.dollars(earlier.cost)
            ))
        }
        let wholePoints = serviceID == "claude" && mode == .subscription
        let showsOutside = wholePoints ? share.outside.rounded() >= 1 : share.outside > 0
        if showsOutside {
            rows.append(LimitsRow(
                id: "outside",
                title: LimitsCopy.outsideTitle,
                subtitle: LimitsCopy.outsideSubtitle(serviceID: serviceID),
                share: wholePoints ? LimitsCopy.wholeShare(share.outside) : LimitsCopy.share(share.outside),
                dollars: ""
            ))
        }
        return rows
    }
}

// MARK: - Chats or projects

/// How the ranked list groups the window (§ The tab, item 3).
enum LimitsGrouping: String, CaseIterable, Sendable {
    case chats, projects
}

extension LimitsRules {
    /// The `UserDefaults` key the Chats / Projects choice is kept under: one string for
    /// every provider, "claude=projects,codex=chats".
    static let groupingKey = "limitsGrouping"

    /// The grouping `serviceID` was left on; Chats until one is chosen.
    nonisolated static func grouping(for serviceID: String, stored: String) -> LimitsGrouping {
        storedGroupings(stored)[serviceID] ?? .chats
    }

    /// `stored` with `serviceID` on `choice`, every other provider's choice kept, in id
    /// order. A pair that no longer reads is dropped.
    nonisolated static func storing(_ choice: LimitsGrouping, for serviceID: String, in stored: String) -> String {
        var groupings = storedGroupings(stored)
        groupings[serviceID] = choice
        return groupings
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: ",")
    }

    /// Every readable "provider=grouping" pair in `stored`.
    private static func storedGroupings(_ stored: String) -> [String: LimitsGrouping] {
        var groupings: [String: LimitsGrouping] = [:]
        for pair in stored.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = LimitsGrouping(rawValue: String(parts[1])) else { continue }
            groupings[String(parts[0])] = value
        }
        return groupings
    }

    /// The window's projects in the share's own ranking, each the sum of its chats, the
    /// first `rowCap` unless all are asked for. Only those are formatted, each named by
    /// the provider's own decoder.
    nonisolated static func projectRows(
        of share: LimitShare,
        serviceID: String,
        showsAll: Bool,
        projectName: (_ providerID: String, _ slug: String) -> String = SessionCopy.projectName(providerID:projectSlug:)
    ) -> LimitsRankedRows {
        let shown = showsAll ? share.projects[...] : share.projects.prefix(rowCap)
        let rows = shown.map { project in
            LimitsRow(
                id: project.id,
                title: projectName(serviceID, project.id),
                subtitle: LimitsCopy.chatCount(project.chats),
                share: LimitsCopy.share(project.points),
                dollars: LimitsCopy.dollars(project.cost)
            )
        }
        return LimitsRankedRows(rows: rows, total: share.projects.count)
    }

    /// The ranked rows of `grouping`.
    nonisolated static func rows(
        of share: LimitShare,
        grouping: LimitsGrouping,
        serviceID: String,
        showsAll: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current,
        projectName: (_ providerID: String, _ slug: String) -> String = SessionCopy.projectName(providerID:projectSlug:)
    ) -> LimitsRankedRows {
        switch grouping {
        case .chats:
            return chatRows(
                of: share, serviceID: serviceID, showsAll: showsAll,
                calendar: calendar, locale: locale, projectName: projectName
            )
        case .projects:
            return projectRows(of: share, serviceID: serviceID, showsAll: showsAll, projectName: projectName)
        }
    }
}

// MARK: - Period picker

/// One entry of the period picker (spec 2026-10-16 limit analytics § The tab, item 1;
/// § Accounts without percent windows, Periods).
enum LimitsPeriod: Hashable, Sendable {
    /// The window or spend period open now.
    case current
    /// A finished window of a subscription, as `LimitShareRules.pastWindows(records:…)`
    /// found it, with the resets its readings named.
    case past(LimitPastWindow)
    /// Pay as you go's 7-day block this many weeks before the last 7 days: 1 is 7–14 days
    /// ago.
    case weeksAgo(Int)
}

extension LimitsRules {
    /// Pay as you go's earlier 7-day blocks that lie wholly inside the 31-day turn horizon.
    static var earlierWeeks: Int {
        Int(LimitShareRules.turnHorizon / LimitShareRules.payAsYouGoPeriod) - 1
    }

    /// The periods the picker offers, the current one first, then newest to oldest:
    /// - Subscription: the finished windows (`pastWindows`);
    /// - Pay as you go: the earlier 7-day blocks;
    /// - Spend limit: the month so far alone, since the turn horizon cannot cover a past
    ///   month; and so for an account with no mode.
    nonisolated static func periods(mode: LimitMode?, pastWindows: [LimitPastWindow]) -> [LimitsPeriod] {
        switch mode {
        case .some(.subscription):
            return [.current] + pastWindows.map { LimitsPeriod.past($0) }
        case .some(.payAsYouGo(_)):
            return [.current] + (1...earlierWeeks).map { LimitsPeriod.weeksAgo($0) }
        case .some(.spendLimit(_, _)), .none:
            return [.current]
        }
    }

    /// Whether the picker shows: only with something besides the current period to pick.
    nonisolated static func canPickPeriod(_ periods: [LimitsPeriod]) -> Bool {
        periods.count > 1
    }

    /// The picked period while it is on offer, else the current one: a window that left
    /// the horizon, or a period of another mode, is not shown.
    nonisolated static func selectedPeriod(_ chosen: LimitsPeriod, offered: [LimitsPeriod]) -> LimitsPeriod {
        offered.contains(chosen) ? chosen : .current
    }

    /// The request a load of `period` makes (§ Accounts without percent windows, Periods):
    /// - the current period: `LimitShareRules.request`'s;
    /// - a past window: the window itself on the bucket of `kind`, cut by the readings that
    ///   named its reset, with no live percent (`LimitShareRules.request(for:bucketID:)`);
    /// - an earlier week: the 7 days that many weeks before the last 7, against the same
    ///   budget.
    ///
    /// nil when the account has nothing to measure, or `period` is not its mode's.
    nonisolated static func request(
        for service: ServiceSnapshot,
        kind: BucketKind,
        period: LimitsPeriod,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar
    ) -> LimitShareRequest? {
        switch period {
        case .current:
            return LimitShareRules.request(
                for: service, kind: kind, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
            )
        case .past(let window):
            guard window.start < window.end,
                  LimitShareRules.mode(of: service, weeklyBudgetUSD: weeklyBudgetUSD) == .subscription,
                  let bucket = LimitShareRules.coreBucket(kind: kind, in: service)
            else { return nil }
            return LimitShareRules.request(for: window, bucketID: bucket.id)
        case .weeksAgo(let weeks):
            guard weeks >= 1,
                  let mode = LimitShareRules.mode(of: service, weeklyBudgetUSD: weeklyBudgetUSD),
                  case .payAsYouGo = mode
            else { return nil }
            let end = now.addingTimeInterval(-Double(weeks) * LimitShareRules.payAsYouGoPeriod)
            return LimitShareRequest(
                mode: mode,
                period: LimitWindow(start: end.addingTimeInterval(-LimitShareRules.payAsYouGoPeriod), end: end),
                bucketID: nil,
                livePercent: nil
            )
        }
    }
}

extension LimitsRules {
    /// The finished windows the picker offers for `serviceID`'s window of `kind`: those
    /// the dashboard's last load found for exactly that provider and kind; none before one
    /// has.
    nonisolated static func pastWindows(
        _ list: DashboardState.LimitPastWindows?, serviceID: String, kind: BucketKind
    ) -> [LimitPastWindow] {
        guard let list, list.serviceID == serviceID, list.kind == kind else { return [] }
        return list.windows
    }
}

// MARK: - Timeline

/// The timeline card as `LimitsTimelineCard` draws it (spec 2026-10-16 limit analytics
/// § The tab, item 4).
struct LimitsTimeline: Equatable, Sendable {
    /// Bottom of the stack first: up to five projects, then Other, then Outside this Mac.
    /// Other and Outside appear only when some half hour has them.
    let series: [LimitsTimelineSeries]
    /// One per half hour that moved, oldest first.
    let bars: [LimitsTimelineBar]
    /// The y axis' marks in points, 0 first; the last is the axis' top.
    let axis: [Double]
}

/// One colour of the stack and its legend entry.
struct LimitsTimelineSeries: Equatable, Sendable, Identifiable {
    /// A project slug, or `LimitsRules.otherSeriesID` / `outsideSeriesID`.
    let id: String
    let name: String
    let token: OMColorToken
}

/// One half hour's bar.
struct LimitsTimelineBar: Equatable, Sendable, Identifiable {
    let start: Date
    /// The half hour's end; the last one ends with the window.
    let end: Date
    /// In `series` order, the empty ones left out.
    let parts: [LimitsTimelinePart]

    var id: Date { start }
    /// The bar's height: how far the percent moved in the half hour.
    var total: Double { parts.last?.top ?? 0 }
}

/// One series' piece of a bar.
struct LimitsTimelinePart: Equatable, Sendable {
    let seriesID: String
    let points: Double
    /// Where the piece starts in the stack.
    let base: Double

    var top: Double { base + points }
}

/// What a card built from a load is built again for (`.task(id:)`): the query the load
/// answered and the share itself. A share cut again after an ingest under the same query
/// and period (the window open now, a past week whose late turns arrived) is a new key,
/// so a card never keeps what it drew from the cut before.
struct LimitsCardKey: Equatable, Sendable {
    let query: LimitsQuery
    let share: LimitShare
}

extension DashboardState.LimitShareLoad {
    /// What a card drawn from this load is keyed on (`LimitsCardKey`).
    var cardKey: LimitsCardKey { LimitsCardKey(query: query, share: share) }
}

extension LimitsRules {
    /// How many projects get a colour of their own; the rest are Other.
    static let timelineProjectCount = 5
    /// The five projects' colours, largest first: the mockup's, from the series tokens.
    static let timelineProjectTokens: [OMColorToken] = [
        .seriesAllModels, .seriesPerModel, .seriesCredits, .seriesSession, .tokenOutput,
    ]
    static let otherSeriesID = "other"
    static let outsideSeriesID = "outside"
    static let otherSeriesToken: OMColorToken = .muted
    static let outsideSeriesToken: OMColorToken = .seriesQuota
    /// A bar's share of its half hour; the rest is the gap beside it.
    static let timelineBarFraction = 0.7

    /// The window's half hours as stacked bars (spec § The tab, item 4): a chat's points go
    /// to its project when that project is one of the window's five largest (by points),
    /// otherwise to Other; Outside this Mac is the half hour's own. A half hour that moved
    /// nothing has no bar. A spend limit's Outside has no time and is not drawn.
    nonisolated static func timeline(
        of share: LimitShare,
        serviceID: String,
        projectName: (_ providerID: String, _ slug: String) -> String = SessionCopy.projectName(providerID:projectSlug:)
    ) -> LimitsTimeline {
        let projectIDs = Array(
            share.projects.filter { $0.points > LimitShareRules.pointSlack }.prefix(timelineProjectCount).map(\.id)
        )
        let projectOfChat = Dictionary(share.chats.map { ($0.id, $0.projectSlug) }, uniquingKeysWith: { first, _ in first })
        var hasOther = false
        var hasOutside = false
        var bars: [LimitsTimelineBar] = []
        for bin in share.bins where bin.delta > LimitShareRules.pointSlack {
            var byProject: [String: Double] = [:]
            var other = 0.0
            for (chat, points) in bin.chats {
                if let project = projectOfChat[chat], projectIDs.contains(project) {
                    byProject[project, default: 0] += points
                } else {
                    other += points
                }
            }
            var pieces: [(String, Double)] = projectIDs.map { ($0, byProject[$0] ?? 0) }
            pieces.append((otherSeriesID, other))
            pieces.append((outsideSeriesID, bin.outside))
            var parts: [LimitsTimelinePart] = []
            var base = 0.0
            for (id, points) in pieces where points > LimitShareRules.pointSlack {
                parts.append(LimitsTimelinePart(seriesID: id, points: points, base: base))
                base += points
            }
            guard !parts.isEmpty else { continue }
            if other > LimitShareRules.pointSlack { hasOther = true }
            if bin.outside > LimitShareRules.pointSlack { hasOutside = true }
            bars.append(LimitsTimelineBar(
                start: bin.start,
                end: min(bin.start.addingTimeInterval(LimitShareRules.binLength), share.window.end),
                parts: parts
            ))
        }
        var series = projectIDs.enumerated().map { index, id in
            LimitsTimelineSeries(id: id, name: projectName(serviceID, id), token: timelineProjectTokens[index])
        }
        if hasOther {
            series.append(LimitsTimelineSeries(id: otherSeriesID, name: LimitsCopy.otherProjects, token: otherSeriesToken))
        }
        if hasOutside {
            series.append(LimitsTimelineSeries(id: outsideSeriesID, name: LimitsCopy.outsideTitle, token: outsideSeriesToken))
        }
        return LimitsTimeline(series: series, bars: bars, axis: timelineAxis(top: bars.map(\.total).max() ?? 0))
    }

    /// The y axis: whole points from 0 up to the tallest bar rounded up, at least 1, in at
    /// most four steps (the mockup's 0 % to 3 %).
    nonisolated static func timelineAxis(top: Double) -> [Double] {
        let ceiling = max(1, (top - LimitShareRules.pointSlack).rounded(.up))
        let step = max(1, (ceiling / 4).rounded(.up))
        let marks = Int((ceiling / step).rounded(.up))
        return (0...marks).map { Double($0) * step }
    }

    /// How far a bar stands in from each edge of its half hour.
    nonisolated static func barInset(_ bar: LimitsTimelineBar) -> TimeInterval {
        bar.end.timeIntervalSince(bar.start) * (1 - timelineBarFraction) / 2
    }

    /// What hovering a bar shows: its half hour, how far the percent rose, and each
    /// series' points in stack order.
    nonisolated static func timelineTooltip(
        for bar: LimitsTimelineBar, in timeline: LimitsTimeline, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> HistoryTooltip {
        let named = Dictionary(timeline.series.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return HistoryTooltip(
            title: LimitsCopy.timeRange(from: bar.start, to: bar.end, now: now, calendar: calendar, locale: locale),
            headline: LimitsCopy.binRise(bar.total),
            rows: bar.parts.map { part in
                HistoryTooltipRow(
                    label: named[part.seriesID]?.name ?? part.seriesID,
                    value: LimitsCopy.binPoints(part.points),
                    token: named[part.seriesID]?.token
                )
            }
        )
    }

    /// Where the x axis is marked: every hour of a session, every day of a week, every
    /// fifth day of a month.
    nonisolated static func timelineStride(span: LimitsSpan) -> HistoryAxisStride {
        switch span {
        case .session: return HistoryAxisStride(component: .hour, count: 1)
        case .week: return HistoryAxisStride(component: .day, count: 1)
        case .month: return HistoryAxisStride(component: .day, count: 5)
        }
    }
}
