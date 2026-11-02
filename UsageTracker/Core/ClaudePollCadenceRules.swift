import Foundation

/// How often Claude's OAuth usage endpoint is asked while Claude Code's status line feeds
/// Claude's two core windows (spec 2026-11-02 Claude limits from the status line,
/// § Design › Cadence).
///
/// With a reading applied in the last five minutes (`StatusLineMergeRules.Result.applied`,
/// at a poll or between polls), a tick asks the endpoint only once
/// `max(refreshIntervalSeconds, 300)` seconds have passed since the poll that last asked —
/// up to `tickTolerance` early — and shows the last answer in between; without one, every
/// tick asks, as before. Anything a person asked for — the popover opening, a Refresh
/// button, a setting, a sign-in coming back — always asks. The endpoint is never switched
/// off: the model-scoped windows, the credit pools and extra usage exist only there. Only
/// Claude is held; every other provider polls as it did.
enum ClaudePollCadenceRules {
    /// Why a poll runs.
    enum Trigger: Equatable, Sendable {
        /// The timer, or the Mac waking: may hold Claude's fetch back.
        case tick
        /// The popover opening (on its own 10 s floor, `AppState.popoverRefreshFloor`), a
        /// Refresh button, a setting, the launch, a sign-in coming back: always asks.
        case asked
    }

    /// A status-line reading applied this recently keeps Claude's fetch slow.
    static let readingHold: TimeInterval = 300
    /// The slowest Claude's endpoint is asked while the status line feeds it, unless the
    /// user's own interval is slower still.
    static let slowInterval: TimeInterval = 300
    /// How early a tick may come and still be the one that is due (session ruling
    /// 2026-11-02): ticks are a sleep apart plus wake lateness, and the work before a poll
    /// varies, so the due tick can land a hair short of the interval.
    static let tickTolerance: TimeInterval = 5

    static func fetchInterval(refreshIntervalSeconds: Int) -> TimeInterval {
        max(TimeInterval(refreshIntervalSeconds), slowInterval)
    }

    /// Whether this poll asks Claude's endpoint. `lastFetchAt` is when the poll that last
    /// asked started; nil before the first. A time in the future — a clock that moved
    /// back — holds nothing.
    static func shouldFetch(
        trigger: Trigger,
        lastFetchAt: Date?,
        statusLineAppliedAt: Date?,
        refreshIntervalSeconds: Int,
        now: Date
    ) -> Bool {
        guard trigger == .tick, let lastFetchAt, let statusLineAppliedAt else { return true }
        let sinceApplied = now.timeIntervalSince(statusLineAppliedAt)
        guard sinceApplied >= 0, sinceApplied <= readingHold else { return true }
        let sinceFetch = now.timeIntervalSince(lastFetchAt)
        guard sinceFetch >= 0 else { return true }
        return sinceFetch + tickTolerance >= fetchInterval(refreshIntervalSeconds: refreshIntervalSeconds)
    }
}
