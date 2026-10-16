import Foundation

/// A span a limit share is cut for: one limit window, or one spend period.
struct LimitWindow: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// What each chat cost in limit percent, and what a percent costs: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design. Pure: the dashboard
/// passes in the account's snapshot, the window's percent readings and the turns its
/// cost log holds, and the Limits tab shows the result.
enum LimitShareRules {
    /// The account's window of `kind`: its first bucket of that kind that is a real
    /// limit. These are not limits:
    /// - a bonus or credit pool;
    /// - the weekly budget Omelette invents for a pay-as-you-go account
    ///   (`CostCopy.syntheticBucketIDs`, kind `.weekly`).
    ///
    /// Only `.session` and `.weekly` count; model-specific windows are out of scope.
    /// The bucket is picked by kind, never by id: Codex names its first lane
    /// `codex_session` whatever its length, and on Prolite that lane is the week.
    nonisolated static func coreBucket(kind: BucketKind, in service: ServiceSnapshot) -> UsageBucket? {
        guard kind == .session || kind == .weekly else { return nil }
        return service.buckets.first {
            $0.kind == kind && !$0.isBonusPool && !CostCopy.syntheticBucketIDs.contains($0.id)
        }
    }

    /// The windows the window switch offers, Session before Week, and only those the
    /// account has. Codex Prolite has the Week alone.
    nonisolated static func windowKinds(of service: ServiceSnapshot) -> [BucketKind] {
        [BucketKind.session, .weekly].filter { coreBucket(kind: $0, in: service) != nil }
    }

    /// The window open now: `resetsAt − windowDuration` to now. If the reading is older
    /// than the reset (a retained snapshot), the window ends at the reset instead. nil
    /// when the bucket names no reset or no length, or the window has not started.
    nonisolated static func currentWindow(of bucket: UsageBucket, now: Date) -> LimitWindow? {
        guard bucket.resetsAt < .distantFuture, let duration = bucket.windowDuration else { return nil }
        let start = bucket.resetsAt.addingTimeInterval(-duration)
        let end = min(now, bucket.resetsAt)
        guard start < end else { return nil }
        return LimitWindow(start: start, end: end)
    }
}

// MARK: - Readings and past windows

/// One reading of a bucket's percent.
struct LimitReading: Equatable, Sendable {
    let time: Date
    /// Clamped to 0...100: a provider can report a hair over its own limit.
    let percent: Double
}

/// A reset found in a bucket's readings: a reading at least `LimitShareRules.resetDrop`
/// points below the one before it, where the drop holds.
struct LimitReset: Equatable, Sendable {
    /// The last reading of the old window. A past window ends here. The turns between
    /// this reading and the drop go to the new window, where the drop's own reading
    /// counts them.
    let lastBefore: Date
    /// The reading the drop landed on.
    let firstAfter: Date
}

extension LimitWindow {
    /// A reading belongs to the window if it is after the start and at or before the
    /// end. A past window runs from the last reading before its reset to the next reset,
    /// and ends on the last reading before that one. The newest past window ends at the
    /// current window's start instead, which is not a reading.
    func containsReading(at time: Date) -> Bool { time > start && time <= end }
}

extension LimitShareRules {
    /// A window's bins. Also the slack within which a reset counts as the current
    /// window's own.
    static let binLength: TimeInterval = 30 * 60
    /// How many points a reading must fall below the one before it to be a reset
    /// rather than noise.
    static let resetDrop: Double = 5

    /// The bucket's readings in time order, from the records `HistoryStore` keeps.
    /// Records without the bucket are skipped.
    nonisolated static func series(_ records: [HistoryRecord], bucketID: String) -> [LimitReading] {
        records
            .compactMap { record in
                record.percent(for: bucketID).map {
                    LimitReading(time: record.timestamp, percent: max(0, min(100, $0)))
                }
            }
            .sorted { $0.time < $1.time }
    }

    /// Every reset in `series` (which must be in time order), oldest first.
    ///
    /// A drop must hold: the reading after it, when there is one, is also at least
    /// `resetDrop` points below the reading before the drop. A lone dip is API noise,
    /// and `monotone(_:in:)` absorbs it. A drop on the last reading has nothing after it
    /// to say otherwise, and counts.
    nonisolated static func resets(in series: [LimitReading]) -> [LimitReset] {
        guard series.count >= 2 else { return [] }
        var out: [LimitReset] = []
        for i in series.indices.dropFirst() {
            let before = series[i - 1].percent
            guard before - series[i].percent >= resetDrop else { continue }
            if i + 1 < series.count, before - series[i + 1].percent < resetDrop { continue }
            out.append(LimitReset(lastBefore: series[i - 1].time, firstAfter: series[i].time))
        }
        return out
    }

    /// The finished windows of a bucket, newest first. Each runs from one reset to the
    /// next. The current window's start, known from the live bucket
    /// (`resetsAt − windowDuration`), counts as a reset, so the newest window ends there
    /// (spec § Design, Window bounds).
    ///
    /// A drop from one bin before `currentStart` on does not open a window:
    /// - within one bin of the start, it is the current window's own reset seen by the
    ///   poll. The provider's clock and the poll's differ by seconds, and a laptop asleep
    ///   at the reset sees the drop later;
    /// - a held drop later inside the current window, such as a limit restored with
    ///   `resetsAt` unchanged, scales the current window's readings before it
    ///   (`restoredReadings(_:in:)`).
    ///
    /// These spans are left out:
    /// - a window that began before `horizonStart`: turns older than the 31-day horizon
    ///   are folded into day totals, so its share could not be told;
    /// - a span where the percent never left 0: that is idle time between two sessions.
    ///
    /// The window before the first reset these readings hold is never listed, because
    /// nothing says where it began.
    nonisolated static func pastWindows(
        series: [LimitReading], before currentStart: Date, horizonStart: Date
    ) -> [LimitWindow] {
        let ownResetFrom = currentStart.addingTimeInterval(-binLength)
        let boundaries = resets(in: series)
            .filter { $0.firstAfter < ownResetFrom }
            .map(\.lastBefore)
        let ends = Array(boundaries.dropFirst()) + [currentStart]
        var windows: [LimitWindow] = []
        for (start, end) in zip(boundaries, ends) where start >= horizonStart && start < end {
            let window = LimitWindow(start: start, end: end)
            guard series.contains(where: { window.containsReading(at: $0.time) && $0.percent > 0 })
            else { continue }
            windows.append(window)
        }
        return Array(windows.reversed())
    }
}

// MARK: - Bins

/// One half hour of a window.
struct LimitBin: Equatable, Sendable {
    let start: Date
    /// Δp: the last monotone reading in the bin minus the last one before it, counting
    /// from 0 at the window's start. 0 for a bin with no reading.
    let delta: Double
}

extension LimitShareRules {
    /// The readings inside `window`, made a running maximum from 0 at its start. A
    /// window does not empty between resets, so a dip is API noise.
    nonisolated static func monotone(_ series: [LimitReading], in window: LimitWindow) -> [LimitReading] {
        var high = 0.0
        return series
            .filter { window.containsReading(at: $0.time) }
            .sorted { $0.time < $1.time }
            .map { reading in
                high = max(high, reading.percent)
                return LimitReading(time: reading.time, percent: high)
            }
    }

    /// How many bins `window` has: whole half hours from its start, the last one cut
    /// short at its end.
    static func binCount(of window: LimitWindow) -> Int {
        max(1, Int((window.end.timeIntervalSince(window.start) / binLength).rounded(.up)))
    }

    /// The bin a turn falls in. A turn belongs to the bin [start, end): whole half hours
    /// since the window's start, clamped to the window's bins.
    static func binIndex(of time: Date, in window: LimitWindow, binCount: Int) -> Int {
        let raw = Int((time.timeIntervalSince(window.start) / binLength).rounded(.down))
        return min(max(raw, 0), binCount - 1)
    }

    /// The bin a reading closes. A reading belongs to the bin (start, end], so a
    /// reading exactly on a boundary closes the earlier bin, and it keeps that bin as
    /// the window grows. The percent it reports is what the turns up to it spent.
    /// Clamped to the window's bins.
    static func readingBinIndex(of time: Date, in window: LimitWindow, binCount: Int) -> Int {
        let raw = Int((time.timeIntervalSince(window.start) / binLength).rounded(.up)) - 1
        return min(max(raw, 0), binCount - 1)
    }

    /// The window's bins, oldest first, from its monotone readings (`monotone(_:in:)`).
    nonisolated static func bins(of window: LimitWindow, readings: [LimitReading]) -> [LimitBin] {
        let count = binCount(of: window)
        var last = [Double?](repeating: nil, count: count)
        for reading in readings where window.containsReading(at: reading.time) {
            last[readingBinIndex(of: reading.time, in: window, binCount: count)] = reading.percent
        }
        var out: [LimitBin] = []
        out.reserveCapacity(count)
        var before = 0.0
        for index in 0..<count {
            let start = window.start.addingTimeInterval(Double(index) * binLength)
            if let value = last[index] {
                out.append(LimitBin(start: start, delta: max(0, value - before)))
                before = max(before, value)
            } else {
                out.append(LimitBin(start: start, delta: 0))
            }
        }
        return out
    }
}

// MARK: - Attribution

extension LimitWindow {
    /// A turn belongs to the window from its start up to, but not including, its end.
    /// So two windows that meet at a reset never both count it.
    func containsTurn(at time: Date) -> Bool { time >= start && time < end }
}

/// One chat's part of a window.
struct ChatShare: Equatable, Sendable, Identifiable {
    /// The chat id the cost log carries (Claude `sessionId`, Codex `session_id`).
    let id: String
    /// The chat's name from the log; nil when it has none.
    let title: String?
    /// The project of the chat's latest main-thread turn in the window, or of its latest
    /// turn when only its sub-agents ran in it.
    let projectSlug: String
    /// Percent points of the window this chat filled.
    let points: Double
    /// API-list dollars the chat spent in the window, its sub-agents included.
    let cost: Double
    let tokens: Int
    /// The chat's last turn in the window.
    let lastAt: Date
}

/// One project's part of a window: the sum of its chats.
struct ProjectShare: Equatable, Sendable, Identifiable {
    /// The provider's project slug.
    let id: String
    let points: Double
    let cost: Double
    let tokens: Int
    /// How many of the window's chats ran in it.
    let chats: Int
}

/// One bin of the timeline: how far the percent moved, and who it went to.
struct LimitBinShare: Equatable, Sendable {
    let start: Date
    let delta: Double
    /// Points per chat id: the bin's own turns', or the previous bin's when the percent
    /// lagged.
    let chats: [String: Double]
    /// Points no local turn explains.
    let outside: Double
}

/// A window's percent split by chat, by project and Outside this Mac.
struct LimitShare: Equatable, Sendable {
    let window: LimitWindow
    /// What the chats and Outside add up to. In the Subscription mode this is the
    /// window's percent now: its last monotone reading, or 0 with none.
    let percent: Double
    /// Every chat with a turn in the window, ranked by points, then dollars, then id.
    let chats: [ChatShare]
    /// Ranked the same way.
    let projects: [ProjectShare]
    /// Outside this Mac: claude.ai, the desktop app, another machine.
    let outside: Double
    /// One per half hour of the window, oldest first.
    let bins: [LimitBinShare]
    /// The window's local API-list dollars and tokens.
    let cost: Double
    let tokens: Int
    /// What one point cost. nil below `LimitShareRules.minimumAttributedPoints` ("Not
    /// enough use yet") and outside the Subscription mode.
    let price: PercentPrice?
    /// Local dollars per model, keyed by display name. The change signal reads the
    /// costliest model from here.
    let costByModel: [String: Double]
    /// The part of `outside` no bin carries. A spend limit's Outside is the server's
    /// month total, which has no time to bin it by. It is 0 in the Subscription mode,
    /// whose Outside lives in the bins. The bins' deltas, this and `earlier`'s points add
    /// up to `percent`.
    let unbinnedOutside: Double
    /// A spend limit's local dollars from before the 31-day turn horizon: the "Earlier
    /// this month" row. It is one row, not split by chat, and never part of Outside. nil
    /// when the turns cover the whole period, and in every other mode.
    let earlier: EarlierLocalShare?

    /// The points local turns explain: the window's percent minus Outside.
    var attributedPoints: Double { percent - outside }
}

extension LimitShareRules {
    /// What the chats spent in one bin. A chat with a turn here counts even at $0.
    private struct BinUse {
        var cost: [String: Double] = [:]
        var tokens: [String: Int] = [:]

        var isEmpty: Bool { cost.isEmpty }

        /// `points` split among the bin's chats. The split is by dollars. If the bin has
        /// no dollars at all (a model no price table knows yet), it is by tokens. If it
        /// has neither, it is even.
        func split(_ points: Double) -> [String: Double] {
            let dollars = cost.values.reduce(0, +)
            if dollars > 0 { return cost.mapValues { points * $0 / dollars } }
            let total = tokens.values.reduce(0, +)
            if total > 0 { return tokens.mapValues { points * Double($0) / Double(total) } }
            return cost.mapValues { _ in points / Double(cost.count) }
        }
    }

    /// Splits the window's percent among the chats that filled it (§ Design, Attribution).
    ///
    /// A bin's Δp goes to:
    /// - its own chats, in proportion to their dollars in the bin, when it has a local
    ///   turn;
    /// - otherwise, the previous bin's chats in that bin's proportions, when the
    ///   previous bin had a turn. The percent lags a turn by up to one step and one
    ///   poll;
    /// - otherwise, Outside this Mac.
    ///
    /// The chats and Outside add up to the window's percent now. A project's share is
    /// the sum of its chats'.
    nonisolated static func share(
        window: LimitWindow,
        bucketID: String,
        readings: [HistoryRecord],
        log: TurnCostLog
    ) -> LimitShare {
        share(window: window, series: series(readings, bucketID: bucketID), log: log)
    }

    /// The same split over a bucket's readings already in `LimitReading` form, such as a
    /// series that ends on the live bucket's percent (`endingOnLive(_:percent:at:)`).
    nonisolated static func share(
        window: LimitWindow,
        series: [LimitReading],
        log: TurnCostLog
    ) -> LimitShare {
        let rising = monotone(series, in: window)
        let cut = bins(of: window, readings: rising)
        let turns = log.turns.filter { window.containsTurn(at: $0.timestamp) }
        let use = binnedUse(turns, in: window, binCount: cut.count)

        var points: [String: Double] = [:]
        var outside = 0.0
        var binShares: [LimitBinShare] = []
        binShares.reserveCapacity(cut.count)
        for (index, bin) in cut.enumerated() {
            var given: [String: Double] = [:]
            var binOutside = 0.0
            if bin.delta > 0 {
                if !use[index].isEmpty {
                    given = use[index].split(bin.delta)
                } else if index > 0, !use[index - 1].isEmpty {
                    given = use[index - 1].split(bin.delta)
                } else {
                    binOutside = bin.delta
                }
            }
            for (chat, part) in given { points[chat, default: 0] += part }
            outside += binOutside
            binShares.append(LimitBinShare(
                start: bin.start, delta: bin.delta, chats: given, outside: binOutside
            ))
        }

        let chats = chatShares(turns: turns, points: points, titles: log.titles)
        let percent = rising.last?.percent ?? 0
        let cost = turns.reduce(0) { $0 + $1.cost }
        let tokens = turns.reduce(0) { TokenBreakdown.saturating($0, $1.tokens.total) }
        return LimitShare(
            window: window,
            percent: percent,
            chats: chats,
            projects: projectShares(chats),
            outside: outside,
            bins: binShares,
            cost: cost,
            tokens: tokens,
            price: price(cost: cost, tokens: tokens, attributedPoints: percent - outside),
            costByModel: costByModel(turns),
            unbinnedOutside: 0,
            earlier: nil
        )
    }

    /// The turns' dollars and tokens per bin and chat.
    private static func binnedUse(_ turns: [TurnCost], in window: LimitWindow, binCount: Int) -> [BinUse] {
        var use = [BinUse](repeating: BinUse(), count: binCount)
        for turn in turns {
            let index = binIndex(of: turn.timestamp, in: window, binCount: binCount)
            use[index].cost[turn.chatID, default: 0] += turn.cost
            use[index].tokens[turn.chatID, default: 0] += turn.tokens.total
        }
        return use
    }

    /// One row per chat with a turn among `turns`, ranked by points, then dollars, then id.
    static func chatShares(
        turns: [TurnCost], points: [String: Double], titles: [String: String]
    ) -> [ChatShare] {
        struct Running {
            var cost = 0.0
            var tokens = 0
            var lastAt = Date.distantPast
            var project = ""
            var projectAt = Date.distantPast
            var projectFromMain = false
        }
        var byChat: [String: Running] = [:]
        for turn in turns {
            var running = byChat[turn.chatID] ?? Running()
            running.cost += turn.cost
            running.tokens = TokenBreakdown.saturating(running.tokens, turn.tokens.total)
            running.lastAt = max(running.lastAt, turn.timestamp)
            // The main thread names the project. A sub-agent's turn names it only until
            // a main-thread turn does.
            let namesProject = turn.isMainThread
                ? !running.projectFromMain || turn.timestamp >= running.projectAt
                : !running.projectFromMain && turn.timestamp >= running.projectAt
            if namesProject {
                running.project = turn.projectSlug
                running.projectAt = turn.timestamp
                running.projectFromMain = turn.isMainThread
            }
            byChat[turn.chatID] = running
        }
        return byChat
            .map { id, running in
                ChatShare(
                    id: id, title: titles[id], projectSlug: running.project,
                    points: points[id] ?? 0, cost: running.cost, tokens: running.tokens,
                    lastAt: running.lastAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.points != rhs.points { return lhs.points > rhs.points }
                if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                return lhs.id < rhs.id
            }
    }

    /// One row per project among `chats`: the sum of its chats, ranked like them.
    static func projectShares(_ chats: [ChatShare]) -> [ProjectShare] {
        struct Running {
            var points = 0.0
            var cost = 0.0
            var tokens = 0
            var chats = 0
        }
        var byProject: [String: Running] = [:]
        for chat in chats {
            var running = byProject[chat.projectSlug] ?? Running()
            running.points += chat.points
            running.cost += chat.cost
            running.tokens = TokenBreakdown.saturating(running.tokens, chat.tokens)
            running.chats += 1
            byProject[chat.projectSlug] = running
        }
        return byProject
            .map { id, running in
                ProjectShare(
                    id: id, points: running.points, cost: running.cost,
                    tokens: running.tokens, chats: running.chats
                )
            }
            .sorted { lhs, rhs in
                if lhs.points != rhs.points { return lhs.points > rhs.points }
                if lhs.cost != rhs.cost { return lhs.cost > rhs.cost }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - Price of a percent

/// What one percent point of a window cost, at API-list prices.
struct PercentPrice: Equatable, Sendable {
    let dollars: Double
    let tokens: Double
}

extension LimitShareRules {
    /// Below this many attributed points there is no price: "Not enough use yet".
    static let minimumAttributedPoints: Double = 1
    /// Points are sums of fractions. A comparison against a threshold allows this much.
    static let pointSlack: Double = 1e-9

    /// The local cost in the window divided by the attributed points, and the tokens
    /// the same way (§ Design, Price of a percent).
    ///
    /// The cost covers every bin with local turns, including those whose percent did
    /// not move. With whole-number percents, a bin whose Δp is 0 still spent quota that
    /// shows in a later step.
    ///
    /// Outside this Mac has no local cost and is not in the points. nil below
    /// `minimumAttributedPoints`.
    nonisolated static func price(cost: Double, tokens: Int, attributedPoints: Double) -> PercentPrice? {
        guard attributedPoints + pointSlack >= minimumAttributedPoints else { return nil }
        return PercentPrice(dollars: cost / attributedPoints, tokens: Double(tokens) / attributedPoints)
    }
}

// MARK: - Change signal

/// "A percent buys about N % less than usual" (§ Design, Change signal).
struct LimitChangeSignal: Equatable, Sendable {
    /// This week's dollars per point.
    let price: Double
    /// The mean of the usual weeks' dollars per point.
    let usualPrice: Double
    /// N: how much less a point buys than usual, in whole percent.
    let percentLess: Int
    /// Set when this week's costliest model is not the one the usual weeks spent most
    /// on. The API price only stands in for how a limit is charged, and a model change
    /// moves it.
    let modelChange: ModelChange?

    struct ModelChange: Equatable, Sendable {
        let usual: String
        let now: String
    }
}

extension LimitShareRules {
    /// The attributed points a week needs before its price is compared.
    static let changeFloorPoints: Double = 10
    /// The signal fires when this week's price falls below this share of the usual one.
    static let changeThreshold: Double = 0.75
    /// The longest window the signal compares: a week, with a day's slack for a past
    /// window, which runs between readings and outlasts seven days when the Mac slept
    /// through a reset.
    static let changeLongestWindow: TimeInterval = 8 * 24 * 3600

    /// Dollars per model, keyed by display name, so a model's dated and undated ids
    /// count as one model.
    static func costByModel(_ turns: [TurnCost]) -> [String: Double] {
        var out: [String: Double] = [:]
        for turn in turns {
            out[ModelPricing.displayName(for: turn.model) ?? turn.model, default: 0] += turn.cost
        }
        return out
    }

    /// The model with the most dollars. A tie goes to the name that sorts first.
    static func costliest(_ costs: [String: Double]) -> String? {
        costs.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }?.key
    }

    /// This week's price against the usual weeks' mean.
    ///
    /// The usual weeks are the previous complete weeks (`pastWindows`) that start inside
    /// the 31-day turn horizon and have at least `changeFloorPoints` attributed points.
    /// The signal fires when this week also has that many points and its price is below
    /// `changeThreshold` of the mean.
    ///
    /// Weekly only, and only for windows of at most `changeLongestWindow`: Codex Free's
    /// 30-day window has kind `.weekly` but is not a week. A longer previous window is
    /// not a usual week either, so early in a 30-day window, while the one before it is
    /// still inside the horizon, there is nothing to compare. nil when it does not fire,
    /// or when there is no usual week to compare.
    nonisolated static func changeSignal(
        kind: BucketKind, current: LimitShare, previous: [LimitShare], horizonStart: Date
    ) -> LimitChangeSignal? {
        func isWeekSized(_ window: LimitWindow) -> Bool {
            window.end.timeIntervalSince(window.start) <= changeLongestWindow
        }
        guard kind == .weekly,
              isWeekSized(current.window),
              current.attributedPoints + pointSlack >= changeFloorPoints,
              let price = current.price?.dollars
        else { return nil }
        let usual = previous.filter {
            isWeekSized($0.window)
                && $0.window.start >= horizonStart
                && $0.window.end <= current.window.start
                && $0.attributedPoints + pointSlack >= changeFloorPoints
                && $0.price != nil
        }
        guard !usual.isEmpty else { return nil }
        let usualPrice = usual.compactMap { $0.price?.dollars }.reduce(0, +) / Double(usual.count)
        guard usualPrice > 0, price < changeThreshold * usualPrice else { return nil }

        var usualModels: [String: Double] = [:]
        for week in usual { usualModels.merge(week.costByModel, uniquingKeysWith: +) }
        let modelChange: LimitChangeSignal.ModelChange?
        if let was = costliest(usualModels), let now = costliest(current.costByModel), was != now {
            modelChange = LimitChangeSignal.ModelChange(usual: was, now: now)
        } else {
            modelChange = nil
        }
        return LimitChangeSignal(
            price: price,
            usualPrice: usualPrice,
            percentLess: Int(((1 - price / usualPrice) * 100).rounded()),
            modelChange: modelChange
        )
    }
}
