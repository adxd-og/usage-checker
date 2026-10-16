import Foundation

/// How the Limits tab measures one account: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Accounts without percent
/// windows. A chat is measured either by the half-hour bins of a percent window, or by
/// dollars against a budget, the period's spend or a spend limit.
enum LimitMode: Equatable, Sendable {
    /// The account has a core session or weekly window. Shares come from
    /// `LimitShareRules.share(window:bucketID:readings:log:)`.
    case subscription
    /// No window of its own, billed per use. `weeklyBudget` is the Claude budget set in
    /// Settings. It is nil when none is set, and always nil for Codex, which has no
    /// budget setting.
    case payAsYouGo(weeklyBudget: Double?)
    /// No core window, and extra usage switched on with a monthly limit: an Enterprise
    /// or Team account with a spend limit. In dollars, as `ExtraUsage` holds them.
    case spendLimit(monthlyLimit: Double, usedCredits: Double)
}

extension LimitShareRules {
    /// The account's mode, from its live snapshot.
    ///
    /// The checks run in this order:
    /// 1. A core window makes a subscription. The synthetic budget bucket is not one
    ///    (`windowKinds(of:)`).
    /// 2. A spend limit comes next. A spend-based Enterprise account has no window
    ///    either, so `CostCopy.isPayAsYouGo` is true for it too.
    /// 3. Pay as you go comes last. The weekly budget counts only for Claude, and only
    ///    when one is set.
    ///
    /// nil for an account with nothing to measure, such as one signed out with no
    /// windows.
    nonisolated static func mode(of service: ServiceSnapshot, weeklyBudgetUSD: Double) -> LimitMode? {
        if !windowKinds(of: service).isEmpty { return .subscription }
        if let extra = service.extraUsage, extra.isEnabled, extra.monthlyLimit > 0 {
            return .spendLimit(monthlyLimit: extra.monthlyLimit, usedCredits: extra.usedCredits)
        }
        guard CostCopy.isPayAsYouGo(service) else { return nil }
        let budget = service.id == "claude" && weeklyBudgetUSD > 0 ? weeklyBudgetUSD : nil
        return .payAsYouGo(weeklyBudget: budget)
    }
}

// MARK: - Shares outside a subscription

/// What a chat's dollars are measured against outside a subscription.
enum SpendDenominator: Equatable, Sendable {
    /// The weekly budget set in Settings: "% of budget".
    case budget(Double)
    /// The period's local spend: "% of spend".
    case spend(Double)
    /// The monthly spend limit.
    case monthlyLimit(Double)

    var dollars: Double {
        switch self {
        case .budget(let d), .spend(let d), .monthlyLimit(let d): return d
        }
    }
}

extension LimitShareRules {
    /// The mode's share denominator (the mode table's "A chat's share" column):
    /// - Pay as you go: the weekly budget when one is set, else the period's local
    ///   spend;
    /// - Spend limit: the monthly limit.
    ///
    /// nil for a subscription, which is measured by its percent, and when there is
    /// nothing to divide by.
    nonisolated static func denominator(for mode: LimitMode, periodSpend: Double) -> SpendDenominator? {
        switch mode {
        case .subscription:
            return nil
        case .payAsYouGo(let budget):
            if let budget, budget > 0 { return .budget(budget) }
            return periodSpend > 0 ? .spend(periodSpend) : nil
        case .spendLimit(let limit, _):
            return limit > 0 ? .monthlyLimit(limit) : nil
        }
    }

    /// A spend limit's Outside this Mac: the server's used credits minus this Mac's
    /// spend in the month, when positive.
    nonisolated static func spendLimitOutside(usedCredits: Double, localSpend: Double) -> Double {
        max(0, usedCredits - localSpend)
    }

    /// The period's chats measured against `denominator`. Each chat's points are its
    /// dollars over the denominator, times 100.
    ///
    /// Outside is `outsideDollars` measured the same way. It has no time, so it is
    /// carried as `unbinnedOutside`, and each bin carries only its own turns' points.
    ///
    /// There is no price: the dollars are the bill, or the organisation's own rate.
    nonisolated static func spendShare(
        period: LimitWindow,
        log: TurnCostLog,
        denominator: SpendDenominator,
        outsideDollars: Double = 0
    ) -> LimitShare {
        let dollars = denominator.dollars
        func percentOf(_ cost: Double) -> Double { dollars > 0 ? cost * 100 / dollars : 0 }

        let turns = log.turns.filter { period.containsTurn(at: $0.timestamp) }
        let cut = bins(of: period, readings: [])
        var binChats = [[String: Double]](repeating: [:], count: cut.count)
        var points: [String: Double] = [:]
        for turn in turns {
            let index = binIndex(of: turn.timestamp, in: period, binCount: cut.count)
            binChats[index][turn.chatID, default: 0] += percentOf(turn.cost)
            points[turn.chatID, default: 0] += percentOf(turn.cost)
        }
        let binShares = cut.indices.map { index in
            LimitBinShare(
                start: cut[index].start,
                delta: binChats[index].values.reduce(0, +),
                chats: binChats[index],
                outside: 0
            )
        }
        let chats = chatShares(turns: turns, points: points, titles: log.titles)
        let outside = percentOf(outsideDollars)
        return LimitShare(
            window: period,
            percent: chats.reduce(0) { $0 + $1.points } + outside,
            chats: chats,
            projects: projectShares(chats),
            outside: outside,
            bins: binShares,
            cost: turns.reduce(0) { $0 + $1.cost },
            tokens: turns.reduce(0) { TokenBreakdown.saturating($0, $1.tokens.total) },
            price: nil,
            costByModel: costByModel(turns),
            unbinnedOutside: outside
        )
    }
}
