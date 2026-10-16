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
        outsideDollars: Double = 0,
        earlierDollars: Double = 0
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
        // Local dollars the turns no longer itemise: one row, never Outside.
        let earlier = earlierDollars >= minimumEarlierDollars
            ? EarlierLocalShare(points: percentOf(earlierDollars), cost: earlierDollars)
            : nil
        return LimitShare(
            window: period,
            percent: chats.reduce(0) { $0 + $1.points } + outside + (earlier?.points ?? 0),
            chats: chats,
            projects: projectShares(chats),
            outside: outside,
            bins: binShares,
            cost: turns.reduce(0) { $0 + $1.cost },
            tokens: turns.reduce(0) { TokenBreakdown.saturating($0, $1.tokens.total) },
            price: nil,
            costByModel: costByModel(turns),
            unbinnedOutside: outside,
            earlier: earlier
        )
    }
}

// MARK: - What the dashboard loads

/// What the dashboard loads for the Limits tab: the account's mode, the current period,
/// and the bucket whose readings the bins are cut from.
struct LimitShareRequest: Equatable, Sendable {
    let mode: LimitMode
    let period: LimitWindow
    /// nil outside the Subscription mode: the other modes have no percent readings.
    let bucketID: String?
    /// The live bucket's percent, clamped to 0...100. `share(for:log:readings:)` ends the
    /// readings on it at the period's end. nil outside the Subscription mode.
    let livePercent: Double?
}

extension LimitShareRules {
    /// Pay as you go's period: the last seven days, the same span the account's
    /// `weekCost` and its budget bucket measure.
    static let payAsYouGoPeriod: TimeInterval = 7 * 24 * 3600

    /// The current period of the account's mode (§ Accounts without percent windows,
    /// Periods):
    /// - Subscription: the current window of `kind`;
    /// - Pay as you go: the last seven days;
    /// - Spend limit: the calendar month so far.
    ///
    /// nil when the account has no mode, or a subscription has no current window of
    /// `kind`. Past periods are Package 3's period picker.
    nonisolated static func request(
        for service: ServiceSnapshot,
        kind: BucketKind,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar
    ) -> LimitShareRequest? {
        guard let accountMode = mode(of: service, weeklyBudgetUSD: weeklyBudgetUSD) else { return nil }
        switch accountMode {
        case .subscription:
            guard let bucket = coreBucket(kind: kind, in: service),
                  let window = currentWindow(of: bucket, now: now)
            else { return nil }
            return LimitShareRequest(
                mode: accountMode, period: window, bucketID: bucket.id,
                livePercent: max(0, min(100, bucket.utilization))
            )
        case .payAsYouGo:
            return LimitShareRequest(
                mode: accountMode,
                period: LimitWindow(start: now.addingTimeInterval(-payAsYouGoPeriod), end: now),
                bucketID: nil,
                livePercent: nil
            )
        case .spendLimit:
            guard let month = calendar.dateInterval(of: .month, for: now), month.start < now else { return nil }
            return LimitShareRequest(
                mode: accountMode, period: LimitWindow(start: month.start, end: now), bucketID: nil,
                livePercent: nil
            )
        }
    }

    /// `series` ending on the live bucket's reading (§ Design, Totals). The
    /// live percent at `time` is appended as the final reading when it is newer than the
    /// last recorded reading or higher than it.
    ///
    /// History lags the live bucket: it is written at most every 30 seconds per service
    /// (`HistoryStore.append`), and only for a healthy poll. With no history at all, the
    /// live percent is the whole window.
    ///
    /// A nil `percent` leaves the series as it is.
    nonisolated static func endingOnLive(
        _ series: [LimitReading], percent: Double?, at time: Date
    ) -> [LimitReading] {
        guard let percent else { return series }
        let live = LimitReading(time: time, percent: max(0, min(100, percent)))
        guard let last = series.last else { return [live] }
        guard live.time > last.time || live.percent > last.percent else { return series }
        return series + [live]
    }

    /// The current window's readings from its last reset on, so the shares total the
    /// window's percent now (spec 2026-10-16 limit analytics § Design, Totals). The last
    /// held drop inside `window`, by `resets(in:)`, ends what came before it:
    /// - the old window's last readings, stamped after the computed start: `resetsAt` is
    ///   rounded to the second, the poll's clock differs, and the old percent can still
    ///   be reported minutes into the new window;
    /// - a limit restored mid-window: the percent falls and `resetsAt` stays.
    ///
    /// The running maximum restarts at the drop's reading. A lone dip is still noise.
    /// Past windows are not cut: each ends at a reset (`pastWindows`), and the newest can
    /// hold the current window's own drop seen up to a bin early.
    nonisolated static func readingsSinceLastReset(
        _ series: [LimitReading], in window: LimitWindow
    ) -> [LimitReading] {
        let inside = series.filter { window.containsReading(at: $0.time) }
        guard let reset = resets(in: inside).last else { return inside }
        return inside.filter { $0.time >= reset.firstAfter }
    }

    /// The share `request` asks for:
    /// - Subscription: the half-hour-bin rule over the bucket's readings since the
    ///   window's last held reset (`readingsSinceLastReset(_:in:)`), ending on the live
    ///   percent at the period's end, so the shares total the percent now;
    /// - Pay as you go and Spend limit: the period's dollars against the mode's
    ///   denominator. A spend limit's Outside is the server's used credits minus the
    ///   period's local spend.
    ///
    /// nil when there is nothing to measure against.
    nonisolated static func share(
        for request: LimitShareRequest,
        log: TurnCostLog,
        readings: [HistoryRecord],
        dailySpend: [CLIDailySummary] = []
    ) -> LimitShare? {
        switch request.mode {
        case .subscription:
            guard let bucketID = request.bucketID else { return nil }
            let readingsToNow = endingOnLive(
                series(readings, bucketID: bucketID), percent: request.livePercent, at: request.period.end
            )
            return share(
                window: request.period, series: readingsSinceLastReset(readingsToNow, in: request.period), log: log
            )
        case .payAsYouGo, .spendLimit:
            let spend = log.turns
                .filter { request.period.containsTurn(at: $0.timestamp) }
                .reduce(0) { $0 + $1.cost }
            guard let denominator = denominator(for: request.mode, periodSpend: spend) else { return nil }
            var outside = 0.0
            var earlier = 0.0
            if case .spendLimit(_, let used) = request.mode {
                // A calendar month can reach past the 31-day turn horizon (31 days and
                // an hour when summer time ends in it). The day totals still hold that
                // spend; the turns do not.
                let monthSpend = max(spend, localSpend(days: dailySpend, in: request.period))
                earlier = monthSpend - spend
                outside = spendLimitOutside(usedCredits: used, localSpend: monthSpend)
            }
            return spendShare(
                period: request.period, log: log, denominator: denominator,
                outsideDollars: outside, earlierDollars: earlier
            )
        }
    }
}

// MARK: - A spend limit's whole month

/// This Mac's dollars in the period that its turns no longer itemise: a spend limit's
/// month-to-date spend from before the 31-day turn horizon, known only from the cost
/// log's day totals. Shown as one row, "Earlier this month", not split by chat, and
/// never part of Outside.
struct EarlierLocalShare: Equatable, Sendable {
    /// Points of the denominator, measured like a chat's.
    let points: Double
    let cost: Double
}

extension LimitShareRules {
    /// Below a cent, the day totals and the turns agree: their sums differ only in
    /// floating-point order.
    static let minimumEarlierDollars: Double = 0.01

    /// This Mac's dollars in `period`, from the cost log's day totals
    /// (`CLIBreakdown.daily`), which survive the fold past the 31-day turn horizon.
    /// A day counts when its start lies in the period. A calendar month starts on a day
    /// boundary of the same calendar the day rows are keyed in.
    nonisolated static func localSpend(days: [CLIDailySummary], in period: LimitWindow) -> Double {
        days
            .filter { $0.day >= period.start && $0.day < period.end }
            .reduce(0) { $0 + $1.totalCost }
    }
}
