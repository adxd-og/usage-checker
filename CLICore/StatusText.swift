import Foundation

/// `omelette status` — the whole output, as one string, from the snapshot alone.
///
/// One line per service: a fixed-width name column so several providers line up, then
/// the windows, the dollars and — for numbers that are no longer live — the stamp,
/// joined by " · ". A final `Agents:` line when anything is running. Every reset is
/// `ResetCopy`'s words, so the terminal and the popover cannot disagree about when a
/// window comes back.
enum StatusText {
    /// Two spaces after the name column. One reads as a typo at a narrow name, three
    /// pushes a five-provider machine off an 80-column terminal.
    static let columnGap = "  "

    static let emptyLine = "No provider is reporting yet."

    static func render(
        snapshot: StatusSnapshot, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let width = nameWidth(snapshot.services)
        var lines = snapshot.services.map {
            serviceLine($0, width: width, now: now, calendar: calendar, locale: locale)
        }
        if let agents = agentsLine(snapshot.agents) { lines.append(agents) }
        guard !lines.isEmpty else { return emptyLine + "\n" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func nameWidth(_ services: [StatusSnapshot.Service]) -> Int {
        services.map(\.name.count).max() ?? 0
    }

    static func serviceLine(
        _ service: StatusSnapshot.Service, width: Int, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var parts = service.windows.map { windowText($0, now: now, calendar: calendar, locale: locale) }
        parts.append(contentsOf: costParts(service))
        // Neither windows nor dollars: the state is the answer to "why is this here?".
        if parts.isEmpty { parts.append(stateText(service.state)) }
        if service.retained,
           let at = service.retainedAt,
           let stamp = ResetCopy.absolute(resetsAt: at, now: now, calendar: calendar, locale: locale) {
            parts.append("(last known \(stamp))")
        }
        // `padding(toLength:)` truncates when the string is longer than the length,
        // which would eat a name; `max` makes that impossible.
        let name = service.name.padding(
            toLength: max(width, service.name.count), withPad: " ", startingAt: 0
        )
        return name + columnGap + parts.joined(separator: " · ")
    }

    /// `Session 42%, resets in 1h 40m (13:00)`. The comma keeps a reset attached to its
    /// own window: with " · " between the two halves, a second window's percent would
    /// look like it belonged to the first window's reset.
    static func windowText(
        _ window: StatusSnapshot.Window, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let head = "\(window.label) \(Int(window.percent.rounded()))%"
        guard let at = window.resetsAt,
              let reset = ResetCopy.both(resetsAt: at, now: now, calendar: calendar, locale: locale)
        else { return head }
        return "\(head), \(reset)"
    }

    /// Zero is not printed: a provider that has a log and spent nothing today is
    /// quieter without "$0.00 today" in the middle of the line.
    static func costParts(_ service: StatusSnapshot.Service) -> [String] {
        var out: [String] = []
        if let today = service.todayCost, today > 0 { out.append(String(format: "$%.2f today", today)) }
        if let week = service.weekCost, week > 0 { out.append(String(format: "$%.2f this week", week)) }
        return out
    }

    /// The words Settings already uses for the same four states.
    static func stateText(_ state: String) -> String {
        switch state {
        case "notSignedIn": return "Sign in needed"
        case "notRunning": return "Not running"
        case "error": return "Error"
        default: return "No data"
        }
    }

    /// Only what is happening. Idle and finished sessions are in `--json`; a line that
    /// said "0 needs you, 0 working" would be noise on every quiet machine.
    static func agentsLine(_ agents: StatusSnapshot.Agents) -> String? {
        var parts: [String] = []
        if agents.needsYou > 0 { parts.append("\(agents.needsYou) needs you") }
        if agents.working > 0 { parts.append("\(agents.working) working") }
        guard !parts.isEmpty else { return nil }
        return "Agents: " + parts.joined(separator: ", ")
    }
}
