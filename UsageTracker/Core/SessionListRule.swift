import Foundation

/// One chat in History's Sessions list, and why it is on it.
struct SessionRow: Identifiable, Equatable, Sendable {
    let session: SessionSummary
    /// The chat earned its place through the cost pick rather than the recent pick, so
    /// the row wears a "top spend" chip: a three-week-old chat in a list of today's is
    /// otherwise a surprise, not information.
    let isTop: Bool

    var id: String { session.id }
}

/// Which chats History shows, and in what order. Pure, so the view calls this and
/// nothing else — and so the same ranking can be re-run for `status.json`.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4.
enum SessionListRule {
    /// The ten most recent. Enough to cover "what was I just doing" on a busy day
    /// without turning the tab into a scrolling log.
    static let defaultRecent = 10
    /// Plus the five most expensive that the recent pick missed — the whole reason the
    /// list is not simply "the last ten".
    static let defaultTop = 5

    /// The order behind "Show all N". Persisted under its raw value, so the cases are a
    /// storage contract: renaming one silently resets every user's toggle.
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recent, cost

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .recent: return "Recent"
            case .cost: return "Cost"
            }
        }
    }

    /// What the chat cost, or 0 for a provider that prices a turn as a whole and leaves
    /// no per-category split. Ranking an unknown as zero is the honest answer: the list
    /// must not promote a chat on a number nobody has.
    static func cost(of session: SessionSummary) -> Double {
        session.tokens.cost?.total ?? 0
    }

    /// The chats on the short list only because of what they cost. Computed once here
    /// and read by both `pick` and `sorted`, so expanding the list never makes a chip
    /// appear or disappear.
    static func topSpendIDs(
        sessions: [SessionSummary], recent: Int = defaultRecent, top: Int = defaultTop
    ) -> Set<String> {
        guard top > 0 else { return [] }
        let recentIDs = recentPickIDs(sessions, recent: recent)
        return Set(
            byCost(sessions)
                .lazy
                .filter { !recentIDs.contains($0.id) }
                .prefix(top)
                .map(\.id)
        )
    }

    /// The `recent` most recent by `lastAt`, plus up to `top` more by cost, merged and
    /// ordered `lastAt` descending.
    static func pick(
        sessions: [SessionSummary], recent: Int = defaultRecent, top: Int = defaultTop
    ) -> [SessionRow] {
        let recentIDs = recentPickIDs(sessions, recent: recent)
        let topIDs = topSpendIDs(sessions: sessions, recent: recent, top: top)
        return byRecency(sessions)
            .filter { recentIDs.contains($0.id) || topIDs.contains($0.id) }
            .map { SessionRow(session: $0, isTop: topIDs.contains($0.id)) }
    }

    /// Every chat, in the order the toggle asks for, chips unchanged.
    static func sorted(
        _ sessions: [SessionSummary], by sort: Sort,
        recent: Int = defaultRecent, top: Int = defaultTop
    ) -> [SessionRow] {
        let topIDs = topSpendIDs(sessions: sessions, recent: recent, top: top)
        let ordered = sort == .recent ? byRecency(sessions) : byCost(sessions)
        return ordered.map { SessionRow(session: $0, isTop: topIDs.contains($0.id)) }
    }

    /// Whether the "Show all N" button has anything to reveal.
    static func canShowAll(shown: Int, total: Int) -> Bool { shown < total }

    // MARK: - Inside one chat

    /// How many sub-agent rows an expanded chat draws before it asks.
    ///
    /// Measured on this Mac: one chat launched 1,235 sub-agents (the next two, 487 and
    /// 244). Eight rows plus the "Main thread" row is a table you can read at a glance,
    /// and the money is concentrated at the top of it — the rest is one button away.
    static let maxAgentRows = 8

    /// How many days an expanded chat draws before it asks. Two weeks covers the 24h,
    /// 7d and 30d ranges whole; a 90-day chat is the one that needs the button.
    static let maxDayRows = 14

    /// Most expensive first, ties by id. Sorted here rather than trusted from the
    /// aggregator: the table's order is a UI decision and belongs with a test.
    static func agentsByCost(_ agents: [SessionAgentSummary]) -> [SessionAgentSummary] {
        agents.sorted {
            let left = $0.tokens.cost?.total ?? 0, right = $1.tokens.cost?.total ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }

    /// The sub-agent rows worth drawing: the `top` most expensive.
    static func pickAgents(
        _ agents: [SessionAgentSummary], top: Int = maxAgentRows
    ) -> [SessionAgentSummary] {
        Array(agentsByCost(agents).prefix(max(0, top)))
    }

    /// The day rows worth drawing: the `limit` most recent, still ascending — the table
    /// reads as a timeline and reversing it to cut the tail would break that.
    static func pickDays(
        _ days: [SessionDaySummary], limit: Int = maxDayRows
    ) -> [SessionDaySummary] {
        let ordered = days.sorted { $0.day < $1.day }
        return Array(ordered.suffix(max(0, limit)))
    }

    /// How many model rows an expanded chat draws before it asks. Six covers a chat
    /// that changed model or effort a few times — the shape a long package day has —
    /// and keeps the table shorter than the sub-agent one above it.
    static let maxModelRows = 6

    /// Most expensive first, ties by key. Sorted here rather than trusted from the
    /// aggregator, exactly as `agentsByCost` is: the table's order is a UI decision and
    /// belongs with a test.
    static func modelsByCost(_ models: [SessionModelSummary]) -> [SessionModelSummary] {
        models.sorted {
            let left = $0.tokens.cost?.total ?? 0, right = $1.tokens.cost?.total ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }

    /// The model rows worth drawing: the `top` most expensive.
    static func pickModels(
        _ models: [SessionModelSummary], top: Int = maxModelRows
    ) -> [SessionModelSummary] {
        Array(modelsByCost(models).prefix(max(0, top)))
    }

    /// Whether the by-model table says anything the rest of the expanded chat doesn't.
    /// One model with no effort is the chat restated — the split line above it already
    /// carries those tokens and those dollars. One model *with* an effort earns its
    /// row: the effort is a fact nothing else on the row states.
    static func showsModels(_ models: [SessionModelSummary]) -> Bool {
        guard models.count == 1 else { return models.count > 1 }
        return models[0].effort != nil
    }

    private static func recentPickIDs(_ sessions: [SessionSummary], recent: Int) -> Set<String> {
        Set(byRecency(sessions).prefix(max(0, recent)).map(\.id))
    }

    /// `lastAt` descending, ties by id ascending. Both halves matter: a list that
    /// reorders itself between two identical reads is a list nobody can click.
    private static func byRecency(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted { $0.lastAt == $1.lastAt ? $0.id < $1.id : $0.lastAt > $1.lastAt }
    }

    private static func byCost(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.sorted {
            let left = cost(of: $0), right = cost(of: $1)
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
