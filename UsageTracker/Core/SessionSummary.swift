import Foundation

/// One chat as the cost logs see it: the main thread plus every sub-agent it
/// launched, with the tokens split by kind and by day. Built by the Claude and
/// Codex aggregators (`CostLogAggregating.sessions(from:to:)`), shown in History's
/// Sessions mode, published to `status.json` and the `get_sessions` MCP tool.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 1.
struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    /// Provider-local session id (Claude `sessionId`, Codex `session_id`).
    let id: String
    /// "claude" or "codex". Grok has no session log.
    let providerID: String
    /// Claude's `ai-title` or the first human prompt; Codex's `thread_name` or the
    /// first user prompt. nil when neither exists — the UI falls back to project + date.
    let title: String?
    let projectSlug: String
    /// Codex `originator` (`codex-tui`, `codex_exec`, `codex_work_desktop`); nil for Claude.
    let origin: String?
    let firstAt: Date
    let lastAt: Date
    let turns: Int
    /// Main thread plus every agent, cost included.
    let tokens: TokenBreakdown
    /// Main thread only.
    let mainTokens: TokenBreakdown
    let agents: [SessionAgentSummary]
    /// Ascending by day; whole session including agents.
    let days: [SessionDaySummary]
    /// One row per (model, effort) pair the chat ran on, most expensive first, ties by
    /// key. The main thread's turns and its sub-agents' both count: the question a row
    /// answers is what this chat spent on that model, not which thread spent it.
    /// Never clipped to a range — see `SessionModelSummary`.
    /// Spec: docs/superpowers/specs/2026-09-10-sessions-by-model-design.md § Design.
    let models: [SessionModelSummary]
}

extension SessionSummary {
    private enum CodingKeys: String, CodingKey {
        case id, providerID, title, projectSlug, origin
        case firstAt, lastAt, turns, tokens, mainTokens
        case agents, days, models
    }

    /// Hand-written for one field: Swift's synthesized decoder ignores a property's
    /// default value and would throw `keyNotFound` on a chat encoded before `models`
    /// existed. Nothing on disk carries a `SessionSummary` today — `status.json` keeps
    /// its own `StatusSnapshot.SessionEntry` — so this is not a migration; it is the
    /// promise that adding a row type never turns an older payload into an error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            providerID: try c.decode(String.self, forKey: .providerID),
            title: try c.decodeIfPresent(String.self, forKey: .title),
            projectSlug: try c.decode(String.self, forKey: .projectSlug),
            origin: try c.decodeIfPresent(String.self, forKey: .origin),
            firstAt: try c.decode(Date.self, forKey: .firstAt),
            lastAt: try c.decode(Date.self, forKey: .lastAt),
            turns: try c.decode(Int.self, forKey: .turns),
            tokens: try c.decode(TokenBreakdown.self, forKey: .tokens),
            mainTokens: try c.decode(TokenBreakdown.self, forKey: .mainTokens),
            agents: try c.decode([SessionAgentSummary].self, forKey: .agents),
            days: try c.decode([SessionDaySummary].self, forKey: .days),
            models: try c.decodeIfPresent([SessionModelSummary].self, forKey: .models) ?? []
        )
    }
}

struct SessionAgentSummary: Codable, Equatable, Sendable, Identifiable {
    /// Claude `agentId` / Codex sub-agent thread id.
    let id: String
    /// Claude `attributionAgent` (the agent type) / Codex `agent_nickname`, or
    /// `agent_path` when the nickname is missing.
    let kind: String
    /// Last model seen on the agent's turns.
    let model: String?
    /// Last effort seen on the agent's turns.
    let effort: String?
    let firstAt: Date
    let lastAt: Date
    let turns: Int
    let tokens: TokenBreakdown
}

/// One (model, effort) pair inside a chat: what it ran and what it cost.
///
/// The model is the raw id the log wrote — the key has to survive a rename of the
/// display rules, and `ModelPricing.displayName` shortens it for the eye only. There
/// is deliberately no per-day split: a chat's model rows describe the whole chat, the
/// way its sub-agent rows do, and the History subtitle already says the list is
/// day-granular.
struct SessionModelSummary: Codable, Equatable, Sendable, Identifiable {
    var id: String { Self.key(model: model, effort: effort) }
    /// The raw id as the log wrote it (`claude-opus-4-5-20251101`, `gpt-5.6-terra`).
    let model: String
    /// `low` / `medium` / `high` / `xhigh` / `max`, or nil when the log has none.
    let effort: String?
    let turns: Int
    let tokens: TokenBreakdown

    /// The string both aggregators bucket a turn by, and the row's own id. One
    /// function rather than the same interpolation in four files.
    static func key(model: String, effort: String?) -> String {
        "\(model)|\(effort ?? "")"
    }

    /// A log that writes `"effort":""` means what a log that omits the field means.
    /// Without this a chat grows two rows for one model, the second labelled with
    /// nothing at all.
    static func effort(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }
}

struct SessionDaySummary: Codable, Equatable, Sendable, Identifiable {
    var id: Date { day }
    /// Local start of day.
    let day: Date
    let turns: Int
    let tokens: TokenBreakdown
}
