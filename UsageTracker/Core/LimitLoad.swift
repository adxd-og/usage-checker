import Foundation

/// What one load of the Limits tab hands the page (spec 2026-10-16 limit analytics § The
/// tab): the period's share with its chats' stretches, the finished windows the period
/// picker offers, and the change signal on the Price of a percent card.
struct LimitLoadResult: Equatable, Sendable {
    /// nil when there is nothing to measure against.
    let share: LimitShare?
    /// By chat id (§ The tab, item 5).
    let stretches: [String: [ChatStretch]]
    /// Newest first (§ The tab, item 1). Empty outside the Subscription mode.
    let pastWindows: [LimitPastWindow]
    /// Only on the current week of a subscription (§ Design, Change signal).
    let change: LimitChangeSignal?
}

extension LimitShareRules {
    /// Whether a load prices the change signal: the current period of a subscription's
    /// weekly window, at most `changeLongestWindow` long (§ Design, Change signal).
    nonisolated static func pricesChange(
        mode: LimitMode, kind: BucketKind, isCurrent: Bool, windowLength: TimeInterval?
    ) -> Bool {
        guard isCurrent, mode == .subscription, kind == .weekly, let windowLength else { return false }
        return windowLength <= changeLongestWindow
    }

    /// The turns a load asks the cost log for: the period's; for the current week, every
    /// turn back to the turn horizon, which prices the usual weeks the change signal
    /// compares.
    nonisolated static func turnSpan(
        request: LimitShareRequest, kind: BucketKind, isCurrent: Bool, windowLength: TimeInterval?, now: Date
    ) -> LimitWindow {
        guard pricesChange(mode: request.mode, kind: kind, isCurrent: isCurrent, windowLength: windowLength)
        else { return request.period }
        return LimitWindow(
            start: min(request.period.start, now.addingTimeInterval(-turnHorizon)),
            end: request.period.end
        )
    }

    /// Everything one load computes, from the turns (`turnSpan`'s), the readings of the
    /// turn horizon, for a spend limit the day totals, and the worktree folds
    /// (`ProjectWorktrees.folds`):
    /// - the share `request` asks for (`share(for:log:readings:dailySpend:)`), its chats'
    ///   projects folded onto the repositories their worktrees belong to
    ///   (`foldingProjects`), and its chats' stretches;
    /// - on a subscription, the finished windows of `bucket` inside the turn horizon,
    ///   before its window open now, or before `now` while none is open;
    /// - on the current week, the change signal against those weeks' prices, each cut by
    ///   the readings that named its reset (`request(for:bucketID:)`).
    ///
    /// `bucket` is the live core bucket of `kind`, nil outside the Subscription mode.
    nonisolated static func loadResult(
        request: LimitShareRequest?,
        kind: BucketKind,
        isCurrent: Bool,
        bucket: UsageBucket?,
        serviceID: String,
        log: TurnCostLog,
        records: [HistoryRecord],
        dailySpend: [CLIDailySummary],
        projectFolds: [String: String] = [:],
        now: Date
    ) -> LimitLoadResult {
        let horizonStart = now.addingTimeInterval(-turnHorizon)
        var past: [LimitPastWindow] = []
        if let bucket, let length = bucket.windowDuration {
            past = pastWindows(
                records: records, bucketID: bucket.id, windowLength: length,
                before: currentWindow(of: bucket, now: now)?.start ?? now, horizonStart: horizonStart
            )
        }
        guard let request,
              let cut = LimitShareRules.share(for: request, log: log, readings: records, dailySpend: dailySpend)
        else {
            return LimitLoadResult(share: nil, stretches: [:], pastWindows: past, change: nil)
        }
        let periodShare = foldingProjects(cut, into: projectFolds)
        var change: LimitChangeSignal?
        if let bucket, let bucketID = request.bucketID,
           pricesChange(mode: request.mode, kind: kind, isCurrent: isCurrent, windowLength: bucket.windowDuration) {
            let previous = past.compactMap { window in
                LimitShareRules.share(
                    for: LimitShareRules.request(for: window, bucketID: bucketID), log: log, readings: records
                )
            }
            change = changeSignal(
                kind: kind, current: periodShare, previous: previous, horizonStart: horizonStart,
                windowLength: bucket.windowDuration
            )
        }
        return LimitLoadResult(
            share: periodShare,
            stretches: stretches(of: periodShare, log: log, serviceID: serviceID),
            pastWindows: past,
            change: change
        )
    }
}
