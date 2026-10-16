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

    /// The query `request` answers: what `DashboardState` publishes with each load. With no
    /// request there is nothing to measure.
    nonisolated static func query(serviceID: String, kind: BucketKind, request: LimitShareRequest?) -> LimitsQuery {
        guard let request else { return LimitsQuery(serviceID: serviceID, kind: kind, measure: nil) }
        let measure: LimitsMeasure
        switch request.mode {
        case .subscription:
            measure = .window(start: toMinute(request.period.start))
        case .payAsYouGo(let budget):
            measure = .payAsYouGo(budget: budget)
        case .spendLimit(let limit, _):
            measure = .spendLimit(monthStart: request.period.start, limit: limit)
        }
        return LimitsQuery(serviceID: serviceID, kind: kind, measure: measure)
    }

    /// The query the live snapshot and settings ask for now: the request
    /// `DashboardState.refreshLimitShare(kind:)` would make (`LimitShareRules.request`).
    nonisolated static func query(
        serviceID: String,
        service: ServiceSnapshot?,
        kind: BucketKind,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar
    ) -> LimitsQuery {
        let request = service.flatMap {
            LimitShareRules.request(
                for: $0, kind: kind, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
            )
        }
        return query(serviceID: serviceID, kind: kind, request: request)
    }
}

extension DashboardState.LimitShareLoad {
    /// The query this load answered.
    var query: LimitsQuery {
        LimitsRules.query(serviceID: serviceID, kind: kind, request: request)
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
        share: LimitShare?
    ) -> (load: DashboardState.LimitShareLoad?, answer: LimitsQuery) {
        let load = request.flatMap { request in
            share.map { DashboardState.LimitShareLoad(serviceID: serviceID, kind: kind, request: request, share: $0) }
        }
        return (load, query(serviceID: serviceID, kind: kind, request: request))
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
    /// 3. a subscription needs its window of `kind` open now;
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
        if mode == .subscription {
            guard let bucket = LimitShareRules.coreBucket(kind: kind, in: service),
                  LimitShareRules.currentWindow(of: bucket, now: now) != nil
            else { return .noOpenWindow(span(of: kind, in: service)) }
        }
        let current = query(
            serviceID: serviceID, service: service, kind: kind,
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
