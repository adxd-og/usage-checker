import Foundation

/// "as of 14:05" stamps for last-known values. Today's reading needs only a time;
/// anything older carries its day, because "as of 09:12" on numbers from Tuesday
/// is worse than no stamp at all.
enum RelativeStamp {
    /// The calendar decides which day it is *and* which zone the clock is read in,
    /// so a test can pin both.
    static func asOf(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        return "\(date.formatted(style.month(.abbreviated).day())), \(time)"
    }
}

/// Every string a retained service shows, in one place — the tile, the popover, the
/// dashboard and the menu bar say the same thing about the same state or they say
/// nothing useful at all.
enum RetainedCopy {
    /// The state chip's word. `.ok` only reaches here when a healthy provider has
    /// nothing to report, which is not a state worth a green badge.
    static func chipText(for state: ServiceState) -> String {
        switch state {
        case .notSignedIn: "Sign in"
        case .notRunning: "Not running"
        case .error: "Error"
        case .ok: "No data"
        }
    }

    /// What follows the chip on a tile: "· as of 14:05". nil for a live service.
    static func chipSuffix(
        for service: ServiceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let at = service.retainedAt else { return nil }
        return "· as of \(RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale))"
    }

    /// The caption under a retained provider's chip in the popover and on the
    /// dashboard: when the numbers were true, and why they stopped moving.
    static func caption(
        for service: ServiceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let at = service.retainedAt else { return nil }
        let stamp = RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
        guard let message = service.stateMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty
        else {
            return "Last known values from \(stamp)"
        }
        return "Last known values from \(stamp) — \(message)"
    }
}
