import Foundation

/// Day keys across a time-zone change.
///
/// The cost aggregators key every day by the local midnight it started at. When the
/// zone moves — a relaunch in another zone, or the system zone changing while the app
/// runs — a saved key names no day of the new calendar, and a range asked in the new
/// zone misses it. A day kept only as a sum is put back where the new calendar looks
/// for it by `midpoint`; a day whose turns are still held is rebuilt from them instead.
///
/// Spec: docs/superpowers/specs/2026-09-24-issue13-chat-day-rebin.md § Design.
enum DayRekey {
    /// A saved day, re-keyed to `calendar`: the start, in `calendar`, of the date the
    /// saved midnight named. The midday after a saved midnight is still that date in
    /// any zone less than twelve hours away, so its start here is the key the Activity
    /// grid, the daily rows and the History ranges ask for. A day saved in this zone
    /// maps onto itself.
    nonisolated static func midpoint(_ saved: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: saved.addingTimeInterval(12 * 3600))
    }
}
