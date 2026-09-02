import Foundation

/// What the dashboard's Agents tab says about finished sessions: the four summary
/// tiles, the day grouping under them, and the strings both use.
///
/// Pure and static on purpose — the screen is a renderer, and every rule here
/// ("which day did this end on", "does a tie go to alpha or beta") is a decision
/// that deserves a test rather than a preview.
struct AgentHistorySummary: Equatable {
    let sessions: Int
    let agentTime: TimeInterval
    let approvalsWaited: Int
    /// nil when nothing is in range. A tuple, so `Equatable` is written by hand below.
    let busiestProject: (name: String, sessions: Int)?

    static func == (lhs: AgentHistorySummary, rhs: AgentHistorySummary) -> Bool {
        lhs.sessions == rhs.sessions
            && lhs.agentTime == rhs.agentTime
            && lhs.approvalsWaited == rhs.approvalsWaited
            && lhs.busiestProject?.name == rhs.busiestProject?.name
            && lhs.busiestProject?.sessions == rhs.busiestProject?.sessions
    }

    /// Records the tab is about: ended inside the range, from the chosen source
    /// (`nil` = every source).
    ///
    /// The window is measured from `endedAt`, not `startedAt`: a run that began last
    /// week and finished ten minutes ago is something you did today. There is no upper
    /// bound — a record stamped slightly in the future by a clock adjustment should
    /// show up, not vanish.
    static func inRange(
        _ records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date
    ) -> [AgentSessionRecord] {
        let cutoff = now.addingTimeInterval(-range.seconds)
        return records.filter { record in
            record.endedAt >= cutoff && (source == nil || record.source == source)
        }
    }

    static func make(
        records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date
    ) -> AgentHistorySummary {
        let scoped = inRange(records, source: source, range: range, now: now)

        var time: TimeInterval = 0
        var approvals = 0
        // Counted in log order so a tie resolves to whichever project was seen first.
        var counts: [String: Int] = [:]
        var order: [String] = []
        for record in scoped {
            time += max(0, record.endedAt.timeIntervalSince(record.startedAt))
            approvals += record.needsYouCount
            if counts[record.project] == nil { order.append(record.project) }
            counts[record.project, default: 0] += 1
        }

        var busiest: (name: String, sessions: Int)?
        for name in order {
            let count = counts[name] ?? 0
            if count > (busiest?.sessions ?? 0) { busiest = (name, count) }
        }

        return AgentHistorySummary(
            sessions: scoped.count,
            agentTime: time,
            approvalsWaited: approvals,
            busiestProject: busiest
        )
    }

    /// The history list: one entry per day that has records, newest day first, and the
    /// newest session first inside each day. Grouped by the day the session *ended*, so
    /// an overnight run appears once, on the morning it finished.
    static func days(
        records: [AgentSessionRecord],
        source: AgentSource?,
        range: TimeRange,
        now: Date,
        calendar: Calendar
    ) -> [(day: Date, records: [AgentSessionRecord])] {
        let scoped = inRange(records, source: source, range: range, now: now)
            .sorted { $0.endedAt > $1.endedAt }
        var days: [(day: Date, records: [AgentSessionRecord])] = []
        for record in scoped {
            let day = calendar.startOfDay(for: record.endedAt)
            if let index = days.firstIndex(where: { $0.day == day }) {
                days[index].records.append(record)
            } else {
                days.append((day: day, records: [record]))
            }
        }
        return days
    }

    /// "Today" / "Yesterday" / "Mon 1 Sep". The weekday form is pinned to
    /// `en_US_POSIX` and to the calendar's own zone: the app's strings are English,
    /// and a title has to name the same day the grouping used.
    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // Built per call rather than cached: a section header asks once per day shown,
        // and a shared mutable formatter would have to be locked (this is nonisolated).
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: day)
    }

    /// "21d 8h" / "3h 12m" / "45m" / "<1m". Minutes are zero-padded inside an hours
    /// string to match `AgentRowText.elapsed`, which draws the live rows on the same
    /// screen. From a day up the minutes are dropped instead: the "Agent time" tile
    /// over a 90-day range would otherwise read `512h 40m`, a number nobody can
    /// picture, and at that scale the minutes are noise. Every unit truncates rather
    /// than rounds, so a total never reads as more time than was actually spent.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "<1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
