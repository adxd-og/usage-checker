import Foundation

/// The `status.json` key a chat's limit share fills: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data and
/// § Accounts without percent windows.
enum PublishedShareField: Hashable, Sendable {
    /// `sessionShare`: points of the current session window.
    case session
    /// `weekShare`: points of the current weekly window.
    case week
    /// `budgetShare`: percent of the weekly budget or of the monthly spend limit.
    case budget
}

/// The window a share was cut for: the key it fills, and the instant that window resets.
/// It stays the same from poll to poll while the window does. So `StatusFileWriter.build`
/// can tell whether a share cut on an earlier poll still belongs to the services it
/// writes (`PublishedShareRules.current`). It never reaches `status.json`.
struct PublishedShareWindow: Hashable, Sendable {
    let field: PublishedShareField
    /// When the window or period resets:
    /// - on a subscription, the bucket's `resetsAt`;
    /// - on a spend limit, the first instant of the next calendar month;
    /// - on pay as you go, nil, because its seven days roll and never reset.
    let resetsAt: Date?
}

/// One share the file publishes for a provider's chats: the window it fills, and the
/// period it is cut from.
struct PublishedShareRequest: Equatable, Sendable {
    let window: PublishedShareWindow
    let request: LimitShareRequest
}

/// What `status.json` and MCP `get_sessions` carry of the Limits rule, per chat. The app
/// works the shares out with `LimitShareRules`, the rule the Limits tab runs. The CLI and
/// the MCP server only read them.
enum PublishedShareRules {
    /// The shares a provider's chats carry, and the period each is cut from:
    /// - a subscription: `sessionShare` and `weekShare`, one per core window the
    ///   account has (Codex Prolite has the week alone). A window whose reset has
    ///   passed is skipped. A retained reading's window is over, and the next one has
    ///   no reading yet;
    /// - pay as you go with a weekly budget, and a spend limit: `budgetShare`, of the
    ///   last seven days or of the calendar month so far;
    /// - pay as you go with no budget: nothing. A share of the period's own spend is
    ///   not a budget.
    ///
    /// Empty for an account with nothing to measure.
    nonisolated static func requests(
        for service: ServiceSnapshot, weeklyBudgetUSD: Double, now: Date, calendar: Calendar
    ) -> [PublishedShareRequest] {
        guard let mode = LimitShareRules.mode(of: service, weeklyBudgetUSD: weeklyBudgetUSD) else { return [] }
        switch mode {
        case .subscription:
            return LimitShareRules.windowKinds(of: service).compactMap { kind -> PublishedShareRequest? in
                guard let bucket = LimitShareRules.coreBucket(kind: kind, in: service),
                      bucket.resetsAt > now,
                      let request = LimitShareRules.request(
                        for: service, kind: kind, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
                      )
                else { return nil }
                let field: PublishedShareField = kind == .session ? .session : .week
                return PublishedShareRequest(
                    window: PublishedShareWindow(field: field, resetsAt: bucket.resetsAt), request: request
                )
            }
        case .payAsYouGo(weeklyBudget: .none):
            return []
        case .payAsYouGo, .spendLimit:
            // Outside a subscription the kind is not read: the period is the mode's own.
            guard let request = LimitShareRules.request(
                for: service, kind: .weekly, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar
            ) else { return [] }
            // A spend limit starts over with the calendar month; pay as you go's seven
            // days roll and never reset.
            var resetsAt: Date?
            if case .spendLimit = mode { resetsAt = calendar.dateInterval(of: .month, for: now)?.end }
            return [PublishedShareRequest(
                window: PublishedShareWindow(field: .budget, resetsAt: resetsAt), request: request
            )]
        }
    }
}
