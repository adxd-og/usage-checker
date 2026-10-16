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
