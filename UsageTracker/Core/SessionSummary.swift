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

struct SessionDaySummary: Codable, Equatable, Sendable, Identifiable {
    var id: Date { day }
    /// Local start of day.
    let day: Date
    let turns: Int
    let tokens: TokenBreakdown
}
