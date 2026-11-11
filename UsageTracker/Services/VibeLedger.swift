import Foundation

/// What Brioche has attributed of Mistral's vibe sessions (spec 2026-11-10 Mistral provider
/// § Local usage (P2), Attribution and What the app has already counted): per session the
/// high-water mark — the highest total attributed — and the steps it went to, each at the moment
/// of the point that first showed it. `VibeUsageAggregator` keeps it on disk because vibe prunes
/// its journal: a pruned segment never moves tokens already counted, and a relaunch finds each
/// day where it was.
struct VibeLedger: Codable, Equatable, Sendable {
    /// The attribution rule's version, not only the file's shape: bump it with any change to
    /// `attribute`, `tidied` or what a step means. A ledger of another version, older or
    /// unknown, is discarded and every session is attributed again from the logs (the spec's
    /// first-point rule for what vibe has pruned).
    static let currentVersion = 1
    /// Steps older than this are dropped: the year the other logs keep.
    static let dayRetention: TimeInterval = 366 * 24 * 3600
    /// Steps older than this fold into one per session and day: nothing reads them finer than
    /// a day (the week and the month reach back 30 days).
    static let foldAge: TimeInterval = 31 * 24 * 3600

    var version = VibeLedger.currentVersion
    var sessions: [String: Session] = [:]

    /// A cumulative reading as vibe counts it: `input` includes `cached`.
    struct Counters: Codable, Equatable, Sendable {
        var input = 0
        var cached = 0
        var output = 0

        /// Saturating, as every count here: a counter near `Int.max` is a wrong number, never a trap.
        var total: Int { TokenBreakdown.saturating(input, output) }
    }

    /// Tokens attributed to one moment: the rise a point showed above the mark before it.
    /// `input` includes `cached`, as vibe counts. `turns` is 1 until old steps fold.
    struct Step: Codable, Equatable, Sendable {
        var at: Date
        var input: Int
        var cached: Int
        var output: Int
        var turns = 1
    }

    /// One session directory.
    struct Session: Codable, Equatable, Sendable {
        /// The high-water mark: the highest total attributed.
        var counted = Counters()
        var steps: [Step] = []
        /// The newest point read, a rise or not: the session's last activity.
        var lastPointAt: Date?
        var meta = VibeSessionStore.Meta()
        /// The directory as last read; nil until it is.
        var mark: VibeSessionStore.Mark?
    }

    /// The steps `points` add above the mark `counted` (plan R3). `points` are in time order.
    /// Each point whose total rises above the mark gives its rise, component by component and
    /// never below zero (vibe's own stats clamp the same way), to its own moment, and becomes the
    /// mark. A point at or below the mark — a repeat, a read that raced vibe's write of a new
    /// generation, a rewritten store — gives nothing and leaves the mark where it was. A negative
    /// mark from a damaged ledger reads as zero.
    static func attribute(_ points: [VibeSessionStore.Point], after counted: Counters) -> (steps: [Step], counted: Counters) {
        var mark = Counters(input: max(0, counted.input), cached: max(0, counted.cached), output: max(0, counted.output))
        var steps: [Step] = []
        for point in points where point.total > mark.total {
            steps.append(Step(
                at: point.at,
                input: rise(point.input, over: mark.input),
                cached: rise(point.cached, over: mark.cached),
                output: rise(point.output, over: mark.output)
            ))
            mark = Counters(point)
        }
        return (steps, mark)
    }

    /// `value − base`, never below zero and never a trap: an overflow reads as `Int.max` when the
    /// base was below zero, as zero otherwise.
    static func rise(_ value: Int, over base: Int) -> Int {
        let (difference, overflow) = value.subtractingReportingOverflow(base)
        if overflow { return base < 0 ? Int.max : 0 }
        return max(0, difference)
    }

    /// The ledger as of `now`: steps older than `dayRetention` dropped; steps older than
    /// `foldAge` merged into one per session and day of `calendar`, at that day's last step,
    /// their counts and turns added, saturating; a session with no step left whose directory has
    /// not moved for `dayRetention` forgotten. A stepless session that moved more recently stays,
    /// so its directory is not read at every poll.
    func tidied(now: Date, calendar: Calendar) -> VibeLedger {
        let dropBefore = now.addingTimeInterval(-Self.dayRetention)
        let foldBefore = now.addingTimeInterval(-Self.foldAge)
        var out = self
        for (id, session) in sessions {
            var kept: [Step] = []
            var folded: [Date: Step] = [:]
            for step in session.steps where step.at >= dropBefore {
                guard step.at < foldBefore else {
                    kept.append(step)
                    continue
                }
                let day = calendar.startOfDay(for: step.at)
                if var merged = folded[day] {
                    merged.at = max(merged.at, step.at)
                    merged.input = TokenBreakdown.saturating(merged.input, step.input)
                    merged.cached = TokenBreakdown.saturating(merged.cached, step.cached)
                    merged.output = TokenBreakdown.saturating(merged.output, step.output)
                    merged.turns = TokenBreakdown.saturating(merged.turns, step.turns)
                    folded[day] = merged
                } else {
                    folded[day] = step
                }
            }
            let steps = (Array(folded.values) + kept).sorted {
                ($0.at, TokenBreakdown.saturating($0.input, $0.output)) < ($1.at, TokenBreakdown.saturating($1.input, $1.output))
            }
            let touched = session.mark?.newest ?? session.lastPointAt ?? .distantPast
            if steps.isEmpty && touched < dropBefore {
                out.sessions[id] = nil
            } else {
                out.sessions[id]?.steps = steps
            }
        }
        return out
    }
}

extension VibeLedger.Counters {
    /// A point's reading as the mark.
    init(_ point: VibeSessionStore.Point) {
        self.init(input: point.input, cached: point.cached, output: point.output)
    }
}
