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

/// The window a share was cut for: the key it fills, the instant that window resets, and
/// for a budget share what it was measured against. It names the same window from poll to
/// poll while the window lasts (`isSameWindow(as:)`). So `StatusFileWriter.build` can tell
/// whether a share cut on an earlier poll still belongs to the services it writes
/// (`PublishedShareRules.current`). It never reaches `status.json`.
struct PublishedShareWindow: Hashable, Sendable {
    let field: PublishedShareField
    /// When the window or period resets:
    /// - on a subscription, the bucket's `resetsAt`;
    /// - on a spend limit, the first instant of the next calendar month;
    /// - on pay as you go, nil, because its seven days roll and never reset.
    let resetsAt: Date?
    /// The dollars a budget share is a percent of: the weekly budget on pay as you go, the
    /// monthly limit on a spend limit. nil for a session or week share, which is measured
    /// by its window's percent.
    var denominatorUSD: Double? = nil

    /// Whether `other` names this window: the same key and denominator, and resets less
    /// than `LimitShareRules.resetDrift` apart, or neither with a reset. A provider reports
    /// a window's reset a second either side from poll to poll, and two windows' resets
    /// are hours apart.
    func isSameWindow(as other: PublishedShareWindow) -> Bool {
        guard field == other.field, denominatorUSD == other.denominatorUSD else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (mine?, theirs?): return abs(mine.timeIntervalSince(theirs)) < LimitShareRules.resetDrift
        default: return false
        }
    }
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
            var denominator: Double?
            switch mode {
            case .spendLimit(let limit, _):
                resetsAt = calendar.dateInterval(of: .month, for: now)?.end
                denominator = limit
            case .payAsYouGo(let budget):
                denominator = budget
            case .subscription:
                break
            }
            return [PublishedShareRequest(
                window: PublishedShareWindow(field: .budget, resetsAt: resetsAt, denominatorUSD: denominator),
                request: request
            )]
        }
    }
}

// MARK: - One chat's fields

/// One chat's shares as `status.json` carries them: percent points to one decimal, nil
/// where a share does not apply.
struct ChatShareFields: Equatable, Sendable {
    var sessionShare: Double? = nil
    var weekShare: Double? = nil
    var budgetShare: Double? = nil
}

extension PublishedShareRules {
    /// Percent points to one decimal, as the file writes them: 3.333… is 3.3, 5.666…
    /// is 5.7.
    nonisolated static func oneDecimal(_ points: Double) -> Double {
        (points * 10).rounded() / 10
    }

    /// Each chat's fields, keyed by chat id, from the shares the requests asked for.
    ///
    /// A chat gets a field for every share it had a turn in, even when that turn moved
    /// nothing (0.0). A share it did not run in leaves the field nil, so the file has no
    /// key for it.
    nonisolated static func fields(_ shares: [PublishedShareField: LimitShare]) -> [String: ChatShareFields] {
        var out: [String: ChatShareFields] = [:]
        for (field, share) in shares {
            for chat in share.chats {
                let points = oneDecimal(chat.points)
                switch field {
                case .session: out[chat.id, default: ChatShareFields()].sessionShare = points
                case .week: out[chat.id, default: ChatShareFields()].weekShare = points
                case .budget: out[chat.id, default: ChatShareFields()].budgetShare = points
                }
            }
        }
        return out
    }
}

// MARK: - From the sources

/// One provider's chat shares, and the windows they were cut for. The windows never reach
/// `status.json`. `StatusFileWriter.build` uses them to write a share only next to the
/// window it was cut for (`current(_:for:weeklyBudgetUSD:now:calendar:)`).
struct PublishedShares: Equatable, Sendable {
    var windows: Set<PublishedShareWindow> = []
    var chats: [String: ChatShareFields] = [:]
}

extension PublishedShareRules {
    /// Where one provider's turns and percent readings come from. The app hands in its
    /// cost log's actor and `HistoryStore`'s (`StatusCosts.shareSources`). A test hands
    /// in fixtures.
    struct Sources: Sendable {
        let turns: @Sendable (_ from: Date, _ to: Date) async -> TurnCostLog
        let readings: @Sendable (_ since: Date) async -> [HistoryRecord]
    }

    /// One provider's chats and their fields, keyed by chat id, with the windows they were
    /// cut for. Empty when the provider publishes no share
    /// (`requests(for:weeklyBudgetUSD:now:calendar:)`), and then its sources are not asked
    /// at all.
    ///
    /// The turns are read once, over the widest period the requests name. The readings
    /// are read once from that period's start, and only when a window needs them. Each
    /// share is then cut by `LimitShareRules.share(for:log:readings:dailySpend:)`, the
    /// rule the Limits tab runs, so the file and the tab agree on every chat. No day
    /// totals are passed: they feed only a spend limit's Earlier row and Outside, and a
    /// chat's points read neither.
    nonisolated static func shares(
        for service: ServiceSnapshot,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar,
        sources: Sources
    ) async -> PublishedShares {
        let wanted = requests(for: service, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar)
        guard let start = wanted.map(\.request.period.start).min(),
              let end = wanted.map(\.request.period.end).max()
        else { return PublishedShares() }
        let log = await sources.turns(start, end)
        var readings: [HistoryRecord] = []
        if wanted.contains(where: { $0.request.bucketID != nil }) {
            readings = await sources.readings(start)
        }
        var cut: [PublishedShareField: LimitShare] = [:]
        var windows: Set<PublishedShareWindow> = []
        for item in wanted {
            guard let share = LimitShareRules.share(for: item.request, log: log, readings: readings) else { continue }
            cut[item.window.field] = share
            windows.insert(item.window)
        }
        return PublishedShares(windows: windows, chats: fields(cut))
    }

    /// Every provider's shares, keyed by service id. These are left out:
    /// - a provider with no entry in `sources`, because its log names no chat (Grok,
    ///   Antigravity);
    /// - a provider with no chat to publish a share for.
    nonisolated static func shares(
        services: [ServiceSnapshot],
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar,
        sources: [String: Sources]
    ) async -> [String: PublishedShares] {
        var out: [String: PublishedShares] = [:]
        for service in services {
            guard let source = sources[service.id] else { continue }
            let provider = await shares(
                for: service, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar, sources: source
            )
            if !provider.chats.isEmpty { out[service.id] = provider }
        }
        return out
    }
}

// MARK: - The last gate

extension PublishedShareRules {
    /// The chats' fields `shares` may still publish for `service` at `now`.
    ///
    /// The shares may be a poll old: the writes between polls reuse them. A field is
    /// kept only while two things hold:
    /// - the requests re-derived from the very services being written still name the
    ///   window it was cut for (`PublishedShareWindow.isSameWindow(as:)`: the same key,
    ///   the same reset give or take a provider's drift, the same budget or limit);
    /// - that window, when it has a reset, resets after `now`.
    ///
    /// So a share never outlives its window's reset. A share of a window the snapshot now
    /// reports with another reset is dropped, and so is a budget share once the budget or
    /// the limit it was cut against changes. A key the account's current mode does not
    /// publish is dropped: session and week after a switch to pay as you go, the budget
    /// once it is cleared.
    nonisolated static func current(
        _ shares: PublishedShares,
        for service: ServiceSnapshot,
        weeklyBudgetUSD: Double,
        now: Date,
        calendar: Calendar
    ) -> [String: ChatShareFields] {
        let named = requests(for: service, weeklyBudgetUSD: weeklyBudgetUSD, now: now, calendar: calendar)
            .map(\.window)
        let live = Set(shares.windows.filter { window in
            named.contains { $0.isSameWindow(as: window) } && (window.resetsAt.map { $0 > now } ?? true)
        }.map(\.field))
        guard !live.isEmpty else { return [:] }
        return shares.chats.mapValues { chat in
            ChatShareFields(
                sessionShare: live.contains(.session) ? chat.sessionShare : nil,
                weekShare: live.contains(.week) ? chat.weekShare : nil,
                budgetShare: live.contains(.budget) ? chat.budgetShare : nil
            )
        }
    }
}
