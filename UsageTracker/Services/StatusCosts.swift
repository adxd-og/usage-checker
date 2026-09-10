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
    /// days of chats. Gathered together because both come off the same actor and the same
    /// incremental `refresh()`; a second pass would re-enter every aggregator for numbers
    /// it has already computed.
    struct Gathered: Sendable {
        var costs: [String: StatusFileWriter.CostEntry] = [:]
        var sessions: [String: [SessionSummary]] = [:]
    }

    /// The window the file's chat list covers (§ 5).
    static let sessionWindow: TimeInterval = 7 * 24 * 3600

    static func gather(serviceIDs: Set<String>, now: Date = Date()) async -> Gathered {
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
        return out
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
