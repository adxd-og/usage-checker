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
    /// end. A past window starts on the last reading of the window before it, and ends
    /// on its own last reading.
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
    /// A drop that landed within one bin before `currentStart`, or after it, is the
    /// current window's own reset seen by the poll. The provider's clock and the poll's
    /// differ by seconds, and a laptop asleep at the reset sees the drop later. Such a
    /// drop does not open a window.
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
