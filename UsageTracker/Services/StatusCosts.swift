import Foundation

/// Today's and this week's dollars per provider, read from the CLIs' own logs, for
/// `status.json`.
///
/// Every call inside is an `await` onto an actor of its own, so the whole function
/// runs off the main actor and a slow log tree delays the file rather than the poll.
/// `refresh()` comes first because `breakdown()` folds only what has been ingested,
/// and on a launch with the dashboard closed nothing else would ever ingest anything;
/// it is incremental — a transcript whose size and mtime have not moved is never
/// reopened — which is what makes it affordable once a minute.
///
/// A provider with no local cost log is simply absent from the result: "no log" and
/// "spent nothing today" are different answers and the file keeps them apart.
enum StatusCosts {
    /// What one poll gathers from the cost logs: the dollars every provider's file entry
    /// carries, and — for the two providers whose logs identify a chat — the last seven
    /// days of chats and each chat's limit shares. Gathered together because all of it
    /// comes off the same actors and the same incremental `refresh()`; a second pass
    /// would re-enter every aggregator for numbers it has already computed.
    struct Gathered: Sendable {
        var costs: [String: StatusFileWriter.CostEntry] = [:]
        var sessions: [String: [SessionSummary]] = [:]
        /// Each provider's chat limit shares and the windows they were cut for (spec
        /// 2026-10-16 § Published data). Claude and Codex only, and only where a share
        /// applies.
        var shares: [String: PublishedShares] = [:]
    }

    /// The window the file's chat list covers (§ 5).
    static let sessionWindow: TimeInterval = 7 * 24 * 3600

    /// `services` is the poll's snapshot and `weeklyBudgetUSD` the budget setting, both
    /// read on the main actor by the caller. So the shares are cut against the windows
    /// the same write publishes.
    ///
    /// The shares are worked out once per poll, after the refreshes. A window's percent
    /// moves only when a poll lands, and the turns only when `refresh()` has ingested
    /// new ones. The writes between polls reuse them (`AppState.lastShares`), and
    /// `StatusFileWriter.build` drops any whose window has gone by then. The turns are
    /// already in memory and the rule is linear in turns and readings, and it runs in a
    /// task the poll does not wait for.
    static func gather(
        serviceIDs: Set<String>,
        services: [ServiceSnapshot] = [],
        weeklyBudgetUSD: Double = 0,
        now: Date = Date()
    ) async -> Gathered {
        var out = Gathered()
        let start = now.addingTimeInterval(-sessionWindow)
        if serviceIDs.contains("claude") {
            await JSONLAggregator.shared.refresh()
            out.costs["claude"] = entry(await JSONLAggregator.shared.breakdown())
            out.sessions["claude"] = await JSONLAggregator.shared.sessions(from: start, to: now)
        }
        if serviceIDs.contains("codex") {
            await CodexUsageAggregator.shared.refresh()
            out.costs["codex"] = entry(await CodexUsageAggregator.shared.breakdown())
            out.sessions["codex"] = await CodexUsageAggregator.shared.sessions(from: start, to: now)
        }
        // Grok is costed and never listed: its log prices a turn without saying which
        // conversation the turn belonged to (`DashboardState.hasSessionLog`).
        if serviceIDs.contains("grok") {
            await GrokUsageAggregator.shared.refresh()
            out.costs["grok"] = entry(await GrokUsageAggregator.shared.breakdown())
        }
        // After the refreshes above, so the turns the shares split are the ones just
        // ingested. Only the providers this gather read.
        out.shares = await PublishedShareRules.shares(
            services: services.filter { serviceIDs.contains($0.id) },
            weeklyBudgetUSD: weeklyBudgetUSD,
            now: now,
            calendar: .current,
            sources: shareSources
        )
        return out
    }

    /// Where each provider whose log names a chat reads its turns and its percent
    /// readings: its cost log's actor, and `HistoryStore`'s. Claude and Codex, the
    /// providers `DashboardState.hasSessionLog` names.
    static var shareSources: [String: PublishedShareRules.Sources] {
        shareSources(readings: { await HistoryStore.shared.records(since: $0, service: $1) })
    }

    /// The same, with the percent history passed in: `readings(since, serviceID)`.
    static func shareSources(
        readings: @escaping @Sendable (Date, String) async -> [HistoryRecord]
    ) -> [String: PublishedShareRules.Sources] {
        [
            "claude": PublishedShareRules.Sources(
                turns: { await JSONLAggregator.shared.turnCosts(from: $0, to: $1) },
                readings: { await readings($0, "claude") }
            ),
            "codex": PublishedShareRules.Sources(
                turns: { await CodexUsageAggregator.shared.turnCosts(from: $0, to: $1) },
                readings: { await readings($0, "codex") }
            ),
        ]
    }

    /// The three numbers out of the whole daily/project/model matrix that the file
    /// carries. Pure, so a swapped today-and-week cannot ship.
    static func entry(_ breakdown: CLIBreakdown) -> StatusFileWriter.CostEntry {
        StatusFileWriter.CostEntry(
            todayCost: breakdown.todayCost,
            weekCost: breakdown.weekCost,
            todayTokens: breakdown.todayTokens
        )
    }
}
