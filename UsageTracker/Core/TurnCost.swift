import Foundation

/// One local turn as the Limits tab reads it: when it ran, which chat and project it
/// belongs to, which model, and what it cost at API-list prices. Built by
/// `CostLogAggregating.turnCosts(from:to:)` from the turns the Claude and Codex
/// aggregators already hold, and read by `LimitShareRules`.
/// Spec: docs/superpowers/specs/2026-10-16-limit-analytics.md § Design, Turns.
///
/// The whole priced `TokenBreakdown` is carried: cache reads, both cache-write TTLs and
/// their dollars. So a chat's stretches (a cold start is a main-thread turn whose cache
/// read is under 5 % of its prompt) need no field this record does not already have.
/// A compaction or a human prompt is an event of the log, not a part of a turn. Each
/// joins `TurnCostLog` as a property of its own.
struct TurnCost: Equatable, Sendable {
    let timestamp: Date
    /// The chat: Claude Code's `sessionId`, or Codex's `session_id`. A sub-agent's turn
    /// carries its parent chat's id, which puts it under that chat.
    let chatID: String
    /// The provider's own project slug: Claude's `~/.claude/projects` child directory, or
    /// Codex's percent-encoded cwd. `ProjectName` decodes it for display.
    let projectSlug: String
    let model: String
    /// The turn's tokens by kind, priced per bucket when the model has a price.
    let tokens: TokenBreakdown
    /// API-list dollars: what the same tokens would cost through the API, never the bill.
    let cost: Double
    /// False on a sub-agent's turn.
    let isMainThread: Bool
}

/// What `turnCosts(from:to:)` answers: every turn in the range, oldest first, and the
/// name of each chat among them that has one.
struct TurnCostLog: Equatable, Sendable {
    var turns: [TurnCost] = []
    /// Chat id → its name: Claude's `ai-title` or first human prompt, or Codex's
    /// `thread_name` or first user prompt. A chat with neither has no entry.
    var titles: [String: String] = [:]

    /// The answer of a provider whose log names no chat.
    static let empty = TurnCostLog()
}
