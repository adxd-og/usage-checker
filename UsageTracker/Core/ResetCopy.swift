import Foundation

/// The words for "when does this window reset", shared by the app's views and the
/// `omelette` command-line tool: a countdown for the glance, an absolute time for the
/// plan ("Thu 14:15" answers "can I finish this before the weekly resets?" — "in 2d 4h"
/// makes you do the arithmetic).
enum ResetCopy {
    /// "in 1h 10m", "in 2d 4h", "now" once the moment has passed. `nil` for a
    /// distant-future placeholder (a provider that reports no reset).
    static func relative(resetsAt: Date, now: Date) -> String? {
        guard resetsAt < Date.distantFuture.addingTimeInterval(-1) else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        guard delta > 0 else { return "now" }
        return "in \(duration(delta))"
    }

    /// "13:00" today, "Thu 14:15" within the next six days, "Sep 14, 14:15" beyond.
    /// Times follow the user's locale (12-hour clocks show "1:00 PM").
    static func absolute(resetsAt: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard resetsAt < Date.distantFuture.addingTimeInterval(-1) else { return nil }
        let time = resetsAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(resetsAt, inSameDayAs: now) { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: resetsAt)).day ?? 0
        if days >= 0, days <= 6 {
            let weekday = resetsAt.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
            return "\(weekday) \(time)"
        }
        let day = resetsAt.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
        return "\(day), \(time)"
    }

    /// "resets in 1h 10m (13:00)"; drops the parenthesis within the hour, where the
    /// countdown is the useful half; "resets now" past the moment; nil when unknown.
    static func both(resetsAt: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let rel = relative(resetsAt: resetsAt, now: now) else { return nil }
        guard rel != "now" else { return "resets now" }
        guard resetsAt.timeIntervalSince(now) > 3600,
              let abs = absolute(resetsAt: resetsAt, now: now, calendar: calendar, locale: locale)
        else { return "resets \(rel)" }
        return "resets \(rel) (\(abs))"
    }

    /// "1h 10m", "2d 4h", "45m" — the app's existing duration spelling.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let h = Int(s / 3600)
        let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if h > 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
