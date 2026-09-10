import Foundation

/// One line of an expanded chat: the main thread, a sub-agent, or a day. A struct of
/// strings rather than a formatted sentence, because the view lays these out in
/// columns — and every one of the strings still comes from a rule with a test.
struct SessionColumns: Identifiable, Equatable, Sendable {
    /// The agent's own id, or "main" for the first row. `ForEach` needs it and the
    /// alternative — indices — would re-identify every row when the cap is lifted.
    let id: String
    let name: String
    let model: String
    let effort: String
    let turns: String
    let tokens: String
    let cost: String
}

/// The by-day table's row. Separate from `SessionColumns` because a day has no model
/// and no effort, and a struct with two permanent dashes in it is a lie.
struct SessionDayColumns: Identifiable, Equatable, Sendable {
    /// The day as ISO-8601, so the id is stable and locale-independent.
    let id: String
    let day: String
    let turns: String
    let tokens: String
    let cost: String
}

/// One expanded chat's three sections, already sorted, capped and turned into strings.
///
/// A value type rather than a set of computed properties on the view for one measured
/// reason: a chat on this Mac has 1,235 sub-agent transcripts, and sorting and
/// formatting them inside `body` would run on every re-render of the list — every poll,
/// every hover, every range click. `SessionRowView` builds this once per (chat, cap
/// state) from a `.task`, off the main actor, the same way `SessionHistoryView` builds
/// its quota cache; a collapsed row builds nothing at all.
struct SessionDetail: Equatable, Sendable {
    let split: String
    let agentsTitle: String
    /// "Main thread" first, then the agents the cap allows. Empty when the chat
    /// launched none — a Main thread row on its own is a table about nothing.
    let agentRows: [SessionColumns]
    let hiddenAgents: Int
    /// The real number, whatever the cap drew.
    let totalAgents: Int
    /// Empty when the chat ran on a single day (§ 4: the table needs `days.count > 1`).
    let dayRows: [SessionDayColumns]
    let hiddenDays: Int
    let totalDays: Int

    static let empty = SessionDetail(
        split: "", agentsTitle: "", agentRows: [], hiddenAgents: 0, totalAgents: 0,
        dayRows: [], hiddenDays: 0, totalDays: 0
    )

    static func build(
        session: SessionSummary,
        allAgents: Bool,
        allDays: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> SessionDetail {
        let agents = session.agents
        let drawnAgents = allAgents
            ? SessionListRule.agentsByCost(agents)
            : SessionListRule.pickAgents(agents)
        let agentRows = agents.isEmpty
            ? []
            : [SessionCopy.mainThreadColumns(session)] + drawnAgents.map(SessionCopy.agentColumns)

        let days = session.days
        let drawnDays = days.count > 1
            ? (allDays ? days.sorted { $0.day < $1.day } : SessionListRule.pickDays(days))
            : []

        return SessionDetail(
            split: SessionCopy.splitLine(session.tokens),
            agentsTitle: SessionCopy.subAgentsTitle(count: agents.count),
            agentRows: agentRows,
            hiddenAgents: max(0, agents.count - drawnAgents.count),
            totalAgents: agents.count,
            dayRows: drawnDays.map { SessionCopy.dayColumns($0, calendar: calendar, locale: locale) },
            hiddenDays: max(0, drawnDays.isEmpty ? 0 : days.count - drawnDays.count),
            totalDays: days.count
        )
    }
}

/// The half of `SessionCopy` that reads the app's own types. Declared here rather than
/// in `CLICore/SessionCopy.swift` because the `omelette` binary compiles that folder and
/// has no `SessionSummary`, `ProjectName` or `ModelPricing` — the same split the design
/// system uses for `TokenCategory.color`.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4.
extension SessionCopy {
    /// "Input 1.2M ($3.60) · Output 340.0k ($5.10) · …" — what the chat's tokens were,
    /// in History's own token vocabulary and its own formatter. Empty buckets are
    /// dropped; thinking comes last and carries no dollars, because it is a slice of
    /// output and pricing it again would count the same money twice.
    static func splitLine(_ breakdown: TokenBreakdown) -> String {
        var parts: [String] = []
        for category in TokenCategory.allCases {
            let tokens = category.tokens(in: breakdown)
            guard tokens > 0 else { continue }
            var part = "\(category.label) \(TokenFormat.formatTokens(tokens))"
            if let dollars = category.cost(in: breakdown) {
                part += " (\(cost(dollars)))"
            }
            parts.append(part)
        }
        if breakdown.thinking > 0 {
            parts.append("Thinking \(TokenFormat.formatTokens(breakdown.thinking))")
        }
        return parts.joined(separator: " · ")
    }

    static func agentColumns(_ agent: SessionAgentSummary) -> SessionColumns {
        SessionColumns(
            id: agent.id,
            name: agent.kind,
            model: agent.model.flatMap { ModelPricing.displayName(for: $0) } ?? "—",
            effort: agent.effort ?? "—",
            turns: "\(agent.turns)",
            tokens: TokenFormat.formatTokens(agent.tokens.total),
            cost: cost(agent.tokens.cost?.total)
        )
    }

    /// The chat's own turns: everything it ran minus everything its agents ran. Clamped
    /// at zero — a clipped range can leave an agent whose turns outnumber the days that
    /// survived the clip, and a negative count reads as a bug in the log.
    static func mainThreadTurns(_ session: SessionSummary) -> Int {
        max(0, session.turns - session.agents.reduce(0) { $0 + $1.turns })
    }

    /// The first row of the sub-agent table, so the agents' share reads against
    /// something. `SessionSummary` carries no model for the chat itself, and borrowing
    /// an agent's would be an invention, so those two columns stay empty.
    static func mainThreadColumns(_ session: SessionSummary) -> SessionColumns {
        SessionColumns(
            id: "main",
            name: "Main thread",
            model: "—",
            effort: "—",
            turns: "\(mainThreadTurns(session))",
            tokens: TokenFormat.formatTokens(session.mainTokens.total),
            cost: cost(session.mainTokens.cost?.total)
        )
    }

    static func dayColumns(
        _ day: SessionDaySummary, calendar: Calendar = .current, locale: Locale = .current
    ) -> SessionDayColumns {
        SessionDayColumns(
            id: ISO8601DateFormatter().string(from: day.day),
            day: dayText(day.day, calendar: calendar, locale: locale),
            turns: "\(day.turns)",
            tokens: TokenFormat.formatTokens(day.tokens.total),
            cost: cost(day.tokens.cost?.total)
        )
    }

    static let byDayTitle = "By day"

    /// The project a chat ran in. Claude's slug is a lossy dash path and is resolved
    /// against the filesystem; Codex's is a percent-encoded absolute path and is not.
    /// Both end in the same display rules, so one project reads identically under
    /// either provider's tab.
    static func projectName(providerID: String, projectSlug: String) -> String {
        providerID == "claude"
            ? ProjectName.decode(slug: projectSlug)
            : ProjectName.decode(encodedPath: projectSlug)
    }

    static func rowTitle(
        _ session: SessionSummary, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        rowTitle(
            title: session.title,
            project: projectName(providerID: session.providerID, projectSlug: session.projectSlug),
            firstAt: session.firstAt,
            calendar: calendar, locale: locale
        )
    }

    static let emptyTitle = "No chats in this period"

    /// The one thing worth adding under the empty state, and only for Codex: a user on
    /// an older CLI has no session logs at all, which is a different fact from a quiet
    /// week and would otherwise read as a broken feature.
    static func emptyHint(providerID: String) -> String? {
        providerID == "codex" ? "Codex writes session logs from 0.146 on" : nil
    }
}
