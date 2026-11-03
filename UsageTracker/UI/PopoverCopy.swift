import Foundation

/// The popover's own words, which no other surface shares: the header's meta line and
/// a tile's plan line (spec § Screens, "Popover · All" and "Popover · provider";
/// `Main.dc.html`, `Popover-Claude.dc.html`).
enum PopoverCopy {
    /// The plan as the tile prints it under the name: "Max 20x" for Claude, "Plus" for
    /// "Codex Plus". nil when there is none, or when it is only the provider's name
    /// again ("Antigravity").
    static func planLine(plan: String?, displayName: String) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespaces), !plan.isEmpty, plan != displayName
        else { return nil }
        let prefix = displayName + " "
        guard plan.hasPrefix(prefix) else { return plan }
        let rest = String(plan.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// A weekly row's label on a provider tab: "Fable only" → "Fable"; "All models"
    /// stays whole (a row has room a 160 pt tile does not).
    static func limitRowLabel(_ label: String) -> String {
        label.hasSuffix(" only") ? String(label.dropLast(" only".count)) : label
    }

    /// The header's second line. A provider tab names the provider and its plan first
    /// ("Claude Max 20x · Updated 7s ago"); All says only when it updated. The age is
    /// `UpdatedCopy`'s, so it reads as the dashboard sidebar's footnote does. A provider
    /// whose windows Claude Code's status line fed says so, and is as old as that reading
    /// — not the poll, not a retained OAuth reading hours back: "… Updated 2m ago from
    /// Claude Code" (spec 2026-11-02 Claude limits from the status line, § Source tag).
    static func metaLine(service: ServiceSnapshot?, fetchedAt: Date, now: Date) -> String {
        guard let service else { return UpdatedCopy.text(fetchedAt: fetchedAt, now: now) }
        let name = [service.displayName, planLine(plan: service.plan, displayName: service.displayName)]
            .compactMap { $0 }
            .joined(separator: " ")
        let fed = service.buckets.filter { $0.source?.words != nil }
        guard let words = fed.first?.source?.words else {
            return "\(name) · \(UpdatedCopy.text(fetchedAt: fetchedAt, now: now))"
        }
        let readAt = fed.compactMap(\.asOf).max() ?? fetchedAt
        return "\(name) · \(UpdatedCopy.text(fetchedAt: readAt, now: now)) \(words)"
    }

    /// The fold under a provider page's weekly limits: how many untouched windows it hides,
    /// or, unfolded, how to hide them again.
    static func unusedWindowsToggle(count: Int, unfolded: Bool) -> String {
        unfolded ? "Hide unused windows" : "\(count) unused windows"
    }

    // MARK: - The island's own words (notch-island spec 2026-10-29 § 3.3)

    /// The strip's title, left of the camera.
    static let appName = "Brioche"
    /// The body before the first poll lands.
    static let loading = "Loading…"
    /// The cannot-refresh notice's tooltip when the failed refresh left no error message.
    static let staleNoticeFallback = "The last refresh attempt failed."

    /// "Can't refresh — showing data from 12:50": the numbers on screen are the last good
    /// ones, from then.
    static func staleNotice(fetchedAt: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = fetchedAt.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
        return "Can't refresh — showing data from \(time)"
    }

    /// The notice's tooltip: why the refresh failed, when the poll said something.
    static func staleNoticeHelp(lastError: String?) -> String {
        guard let lastError, !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return staleNoticeFallback
        }
        return lastError
    }
}
