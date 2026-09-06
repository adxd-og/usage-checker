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
    static func gather(serviceIDs: Set<String>) async -> [String: StatusFileWriter.CostEntry] {
        var out: [String: StatusFileWriter.CostEntry] = [:]
        if serviceIDs.contains("claude") {
            await JSONLAggregator.shared.refresh()
            out["claude"] = entry(await JSONLAggregator.shared.breakdown())
        }
        if serviceIDs.contains("codex") {
            await CodexUsageAggregator.shared.refresh()
            out["codex"] = entry(await CodexUsageAggregator.shared.breakdown())
        }
        if serviceIDs.contains("grok") {
            await GrokUsageAggregator.shared.refresh()
            out["grok"] = entry(await GrokUsageAggregator.shared.breakdown())
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
