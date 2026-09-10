import Foundation

/// Every string History's Sessions list, `status.json` and the `get_sessions` MCP tool
/// put in front of a person.
///
/// This half takes primitives only, because it is compiled into the `omelette` binary
/// as well as the app: the CLI target lists `CLICore/` in its sources and cannot see
/// `SessionSummary`, `ProjectName` or `ModelPricing`. The half that reads those types is
/// `UsageTracker/Core/SessionCopy+Summary.swift`, an extension of this enum in the app
/// target — the same split the design system uses for `TokenCategory.color`.
///
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4, § 5.
enum SessionCopy {
    /// "Today 14:05" in a column, "today 14:05" inside a sentence. Only today's word
    /// changes; a weekday and a date are names in either style.
    enum TimeStyle: Sendable { case row, sentence }

    /// The chat's own name — Claude's `ai-title` or first prompt, Codex's `thread_name`
    /// — or, when neither provider found one, the project and the day it started, which
    /// is what a person recognises a nameless chat by.
    static func rowTitle(
        title: String?, project: String, firstAt: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "\(project) · \(dayText(firstAt, calendar: calendar, locale: locale))"
    }

    /// "Today 14:05" today, "Tue 09:12" within the last six days, "3 Sep" beyond — the
    /// same ladder `ResetCopy.absolute` climbs for a reset, read backwards. Past a week
    /// the minute stops mattering and the date is what places the chat.
    static func lastActive(
        _ date: Date, now: Date, style: TimeStyle = .row,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let time = date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened,
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ))
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(style == .row ? "Today" : "today") \(time)"
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days >= 0, days <= 6 {
            let weekday = date.formatted(Date.FormatStyle(
                locale: locale, calendar: calendar, timeZone: calendar.timeZone
            ).weekday(.abbreviated))
            return "\(weekday) \(time)"
        }
        return dayText(date, calendar: calendar, locale: locale)
    }

    /// A day in the user's own spelling — "3 Sep" in en_GB, "Sep 3" in en_US. The same
    /// style `ResetCopy.absolute` uses for a date beyond this week.
    static func dayText(
        _ date: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        date.formatted(Date.FormatStyle(
            locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ).month(.abbreviated).day())
    }

    static func turns(_ count: Int) -> String {
        count == 1 ? "1 turn" : "\(count) turns"
    }

    /// nil when the chat launched none — a row saying "0 sub-agents" is noise on every
    /// ordinary chat.
    static func subAgents(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 sub-agent" : "\(count) sub-agents"
    }

    static func subAgentsTitle(count: Int) -> String { "Sub-agents (\(count))" }

    /// The chip that tells a Codex chat an agent drove from one the user typed. nil for
    /// every other origin, Claude's absent one included: a chip on every row says
    /// nothing, and this one is only worth a badge because it is rare.
    static func originChip(_ origin: String?) -> String? {
        guard let origin, origin.lowercased().contains("exec") else { return nil }
        return "exec"
    }

    /// Dollars the way every other cost row in the app spells them; "—" for a chat whose
    /// provider prices a turn as a whole and left no per-category split.
    static func cost(_ dollars: Double?) -> String {
        guard let dollars else { return "—" }
        return String(format: "$%.2f", dollars)
    }

    /// The chip on a chat that is on the short list for what it cost rather than for
    /// when it ran.
    static let topSpendChip = "top spend"

    /// "15 of 34 chats" while the list is cut, "4 chats" when it is all of them.
    static func listHeader(shown: Int, total: Int) -> String {
        let noun = total == 1 ? "chat" : "chats"
        return shown < total ? "\(shown) of \(total) \(noun)" : "\(total) \(noun)"
    }

    /// The chat list's column titles, in the order the wide row draws them: the chat
    /// itself, then the four values to its right. Three unlabelled figures on a row
    /// are digits nobody can read; these are the same titles the by-day tables carry.
    static let listColumns = ["Chat", "Last active", "Turns", "Tokens", "Cost"]

    static func showAll(count: Int, expanded: Bool) -> String {
        expanded ? "Show fewer" : "Show all \(count)"
    }

    /// An expanded chat draws only its eight most expensive sub-agents and its fourteen
    /// most recent days (`SessionListRule.maxAgentRows` / `maxDayRows`) — one chat on
    /// this Mac launched 1,235 agents. The button names what it is hiding, because
    /// "Show all 1235" under a table of eight rows says nothing about what those are.
    static func showAllAgents(count: Int, expanded: Bool) -> String {
        guard !expanded else { return "Show fewer" }
        return "Show all \(count) \(count == 1 ? "sub-agent" : "sub-agents")"
    }

    static func showAllDays(count: Int, expanded: Bool) -> String {
        guard !expanded else { return "Show fewer" }
        return "Show all \(count) \(count == 1 ? "day" : "days")"
    }
}
