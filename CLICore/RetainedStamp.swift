import Foundation

/// "as of 14:05" stamps for last-known values. Today's reading needs only a time;
/// anything older carries its day, because "as of 09:12" on numbers from Tuesday
/// is worse than no stamp at all — and its year, when that differs too.
///
/// In CLICore rather than beside the app's views because the `omelette` status line
/// stamps retained numbers too, and the CLI target compiles this folder, not the app.
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
        // "31 Dec, 23:55" in January reads as last week, not last year. A machine
        // that was asleep over the new year is exactly when this file is read.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear ? style.month(.abbreviated).day() : style.year().month(.abbreviated).day()
        return "\(date.formatted(day)), \(time)"
    }
}

/// Every string a retained service shows, in one place — the tile, the popover, the
/// dashboard, the menu bar and the status line say the same thing about the same
/// state or they say nothing useful at all.
///
/// Declared here with the one phrase that needs nothing but a date, so the CLI can say
/// it. The chip, its suffix and the caption read `ServiceSnapshot`, an app type, and
/// live in `UsageTracker/UI/RetainedCopy.swift` as an extension of this enum.
enum RetainedCopy {
    /// "as of 14:05": when last-known numbers were true. The tile's chip suffix is this
    /// with a dot in front; the status line puts it in brackets after the number.
    static func asOf(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        "as of \(RelativeStamp.asOf(date, now: now, calendar: calendar, locale: locale))"
    }
}
