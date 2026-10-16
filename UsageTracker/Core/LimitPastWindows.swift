import Foundation

/// A finished window of a bucket (spec 2026-10-16 limit analytics § Design, Window bounds;
/// § The tab, item 1), and the resets its readings named.
struct LimitPastWindow: Hashable, Sendable {
    let start: Date
    let end: Date
    /// The lowest and highest reset its readings reported: a provider's reported reset
    /// wanders a little from poll to poll. nil for a window the held-drop rule found in
    /// readings that reported none.
    let resets: ClosedRange<Date>?

    var window: LimitWindow { LimitWindow(start: start, end: end) }
}

// MARK: - Past windows from reset times

extension LimitShareRules {
    /// How long both cost logs keep per-turn records (`recentWindow`) before folding them
    /// into day totals. A window, period or week that began earlier cannot be split by chat
    /// (spec § The tab, item 1: "inside the 31-day horizon").
    static let turnHorizon: TimeInterval = 31 * 24 * 3600

    /// How far apart two readings in a row may put their window's reset and still name one
    /// window. A reported reset wandered at most 2 s between polls on this Mac, and one that
    /// wanders by minutes is still its window; two windows' resets are at least ten minutes
    /// apart, since Claude's sit on ten-minute marks (the closest two here were twenty
    /// minutes apart).
    static let resetDrift: TimeInterval = 10 * 60

    /// The finished windows of a bucket, newest first (spec § Design, Window bounds; § The
    /// tab, item 1).
    ///
    /// Readings that named a reset (`HistoryRecord.resetsAt(for:)`) are taken in time
    /// order: one whose reset is less than `resetDrift` from the previous reset-bearing
    /// reading's is the same window; otherwise a new one. A window runs `[high − length,
    /// high]`: `high` is the highest reset its readings named, `length` the one its latest
    /// reading recorded (`windowLength(for:)`), else `windowLength`, the live bucket's. The
    /// window whose resets reach within `resetDrift` of `currentStart + windowLength` is the
    /// one open now and is not listed. No drop has to be seen: a session that never
    /// reached 5 % is a window like any other, and a limit restored mid-week, which keeps
    /// its reset, does not split the week.
    ///
    /// Readings that named no reset (Codex's before this release, or an older build's run
    /// between two of this one's) go through the held-drop rule (`resets(in:)`) wherever
    /// they fall. A drop is a boundary when one of its two readings named no reset and no
    /// one window's reset-bearing readings lie on both sides of it (that would be a limit
    /// restored inside it). It begins the next window at the reset a window named between
    /// its two readings, or else at the reading before it. Seen up to a bin before
    /// `currentStart`, it is the open window's own reset: a window found by the held-drop
    /// rule before it ends on that reading instead. A window whose readings named a reset
    /// still ends at the highest reset they named. After a window's reset another began
    /// even where no reading named it.
    ///
    /// Each window ends where the next one began, at `currentStart`, and at its own reset.
    /// These are left out, as by `pastWindows(series:before:horizonStart:)`:
    /// - a window that began before `horizonStart`;
    /// - a window whose readings never left 0: there is nothing to split.
    nonisolated static func pastWindows(
        records: [HistoryRecord],
        bucketID: String,
        windowLength: TimeInterval,
        before currentStart: Date,
        horizonStart: Date
    ) -> [LimitPastWindow] {
        let readings = records
            .compactMap { record -> TimedReading? in
                guard let percent = record.percent(for: bucketID) else { return nil }
                return TimedReading(
                    time: record.timestamp,
                    percent: max(0, min(100, percent)),
                    resetsAt: record.resetsAt(for: bucketID),
                    length: record.windowLength(for: bucketID)
                )
            }
            .sorted { $0.time < $1.time }
        let currentReset = currentStart.addingTimeInterval(windowLength)

        // 1. Runs of readings that named one reset, reading to reading.
        var groups: [ResetGroup] = []
        var groupOf = [Int?](repeating: nil, count: readings.count)
        for (index, reading) in readings.enumerated() {
            guard let reset = reading.resetsAt else { continue }
            if let last = groups.last, abs(reset.timeIntervalSince(last.latest)) < resetDrift {
                groups[groups.count - 1].add(reading, reset: reset)
            } else {
                groups.append(ResetGroup(reading, reset: reset, fallbackLength: windowLength))
            }
            groupOf[index] = groups.count - 1
        }
        func isCurrent(_ group: ResetGroup) -> Bool {
            currentReset > group.low.addingTimeInterval(-resetDrift)
                && currentReset < group.high.addingTimeInterval(resetDrift)
        }

        // 2. Held drops among readings that named no reset: the rule of `resets(in:)`, by
        // index.
        var dropStarts: [Date] = []
        var ownResetSeenEarly: Date?
        for after in readings.indices.dropFirst() {
            let before = after - 1
            let level = readings[before].percent
            guard level - readings[after].percent >= resetDrop else { continue }
            if after + 1 < readings.count, level - readings[after + 1].percent < resetDrop { continue }
            guard readings[before].resetsAt == nil || readings[after].resetsAt == nil else { continue }
            let groupBefore = groupOf[...before].reversed().first(where: { $0 != nil }) ?? nil
            let groupAfter = groupOf[after...].first(where: { $0 != nil }) ?? nil
            if let groupBefore, groupBefore == groupAfter { continue }
            let lastBefore = readings[before].time
            let firstAfter = readings[after].time
            if firstAfter > currentStart { continue }
            if firstAfter > currentStart.addingTimeInterval(-binLength) {
                ownResetSeenEarly = min(ownResetSeenEarly ?? lastBefore, lastBefore)
                continue
            }
            let known = groups.map(\.high).first { $0 > lastBefore && $0 <= firstAfter }
            dropStarts.append(known ?? lastBefore)
        }

        // 3. Where each window began.
        let spans = groups.map { (start: $0.start, end: $0.high) }
        func coveredByAWindow(_ moment: Date) -> Bool {
            spans.contains { moment > $0.start.addingTimeInterval(-resetDrift) && moment < $0.end }
        }
        var candidates: [Candidate] = []
        for group in groups where !isCurrent(group) {
            candidates.append(Candidate(
                start: group.start, ownEnd: group.high, resets: group.low...group.high, leftZero: group.leftZero
            ))
        }
        var unnamedStarts = Set(dropStarts.filter { start in
            !spans.contains { abs($0.start.timeIntervalSince(start)) < resetDrift }
        })
        for group in groups where !isCurrent(group) && !coveredByAWindow(group.high) {
            unnamedStarts.insert(group.high)
        }
        for start in unnamedStarts {
            candidates.append(Candidate(start: start, ownEnd: nil, resets: nil, leftZero: false))
        }

        // 4. Where each window ended, and which ones count.
        let starts = candidates.map(\.start) + [currentStart]
        var windows: [LimitPastWindow] = []
        for candidate in candidates {
            var end = starts.filter { $0 > candidate.start }.min() ?? currentStart
            end = min(end, currentStart)
            if let ownEnd = candidate.ownEnd { end = min(end, ownEnd) }
            // The open window's own drop seen early clips only a window the held-drop rule
            // found; one whose readings named a reset ends at that reset.
            if candidate.ownEnd == nil, let ownResetSeenEarly, ownResetSeenEarly > candidate.start {
                end = min(end, ownResetSeenEarly)
            }
            guard candidate.start >= horizonStart, candidate.start < end else { continue }
            let span = LimitWindow(start: candidate.start, end: end)
            let leftZero = candidate.leftZero || readings.contains {
                $0.resetsAt == nil && $0.percent > 0 && span.containsReading(at: $0.time)
            }
            guard leftZero else { continue }
            windows.append(LimitPastWindow(start: candidate.start, end: end, resets: candidate.resets))
        }
        return windows.sorted { $0.start > $1.start }
    }

    /// One reading with what it said of its window.
    private struct TimedReading {
        let time: Date
        let percent: Double
        let resetsAt: Date?
        let length: TimeInterval?
    }

    /// A run of readings that named one window's reset.
    private struct ResetGroup {
        var low: Date
        var high: Date
        /// The reset the run's latest reading named: the next reading is compared with it.
        var latest: Date
        var length: TimeInterval
        var leftZero: Bool

        init(_ reading: TimedReading, reset: Date, fallbackLength: TimeInterval) {
            low = reset
            high = reset
            latest = reset
            length = reading.length ?? fallbackLength
            leftZero = reading.percent > 0
        }

        mutating func add(_ reading: TimedReading, reset: Date) {
            low = min(low, reset)
            high = max(high, reset)
            latest = reset
            if let recorded = reading.length { length = recorded }
            leftZero = leftZero || reading.percent > 0
        }

        var start: Date { high.addingTimeInterval(-length) }
    }

    /// Where a window may have begun, before its end is known.
    private struct Candidate {
        let start: Date
        /// A window whose readings named its reset ends there at the latest.
        let ownEnd: Date?
        let resets: ClosedRange<Date>?
        /// Whether its own readings left 0.
        let leftZero: Bool
    }
}

// MARK: - A past window's readings

extension LimitShareRules {
    /// A past window's readings when its readings named its reset (spec § Design, Window
    /// bounds), in time order:
    /// - every reading that named a reset in `resets`, whenever the poll stamped it. Its
    ///   time is held inside `window`, so the window's last reading counts though it was
    ///   stamped seconds after the window ended;
    /// - every reading that named no reset, by its time (`containsReading(at:)`).
    ///
    /// A reading that named another reset is another window's, inside this one's span or
    /// not.
    nonisolated static func series(
        _ records: [HistoryRecord], bucketID: String, resets: ClosedRange<Date>, in window: LimitWindow
    ) -> [LimitReading] {
        // A reading exactly on the start is the window before's (`containsReading(at:)`).
        let firstInside = window.start.addingTimeInterval(1)
        return records
            .compactMap { record -> LimitReading? in
                guard let percent = record.percent(for: bucketID) else { return nil }
                let clamped = max(0, min(100, percent))
                if let reported = record.resetsAt(for: bucketID) {
                    guard resets.contains(reported) else { return nil }
                    return LimitReading(time: min(max(record.timestamp, firstInside), window.end), percent: clamped)
                }
                guard window.containsReading(at: record.timestamp) else { return nil }
                return LimitReading(time: record.timestamp, percent: clamped)
            }
            .sorted { $0.time < $1.time }
    }

    /// What a past window's share is cut from: the window on its bucket, with the resets its
    /// readings named and no live percent, since its readings end where it ended.
    nonisolated static func request(for past: LimitPastWindow, bucketID: String) -> LimitShareRequest {
        LimitShareRequest(
            mode: .subscription, period: past.window, bucketID: bucketID, livePercent: nil, resets: past.resets
        )
    }
}
