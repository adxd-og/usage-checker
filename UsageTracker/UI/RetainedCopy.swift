import Foundation

/// The half of `RetainedCopy` that reads app types. The enum itself, `RelativeStamp`
/// and the date-only `asOf` phrase are in `CLICore/RetainedStamp.swift`, which the
/// `omelette` CLI compiles too.
extension RetainedCopy {
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
        return "· \(asOf(at, now: now, calendar: calendar, locale: locale))"
    }

    /// A provider's error can be a whole response body. The caption is one line
    /// under a chip, so the message it carries ends where a reader can see it end.
    static let maxMessageLength = 120

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
        return "Last known values from \(stamp) — \(cut(message))"
    }

    /// What a retained tile writes over its time, instead of a countdown to a reset it
    /// can no longer see (spec § Screens, "Popover · All": a closed Antigravity shows
    /// "Last known 12:50", no "resets now").
    static let lastKnownTitle = "Last known"

    /// "12:50" today, "24 Sep, 12:50" on an older reading: when a retained service's
    /// numbers were true. nil for a live service. The same stamp as `caption`, so the
    /// tile and the provider tab agree.
    static func lastKnownStamp(
        for service: ServiceSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let at = service.retainedAt else { return nil }
        return RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
    }

    private static func cut(_ text: String) -> String {
        guard text.count > maxMessageLength else { return text }
        return String(text.prefix(maxMessageLength - 1)) + "…"
    }
}
