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
/// A compaction or a human prompt is an event of the log, not a part of a turn: each is
/// a property of `TurnCostLog` of its own (spec 2026-10-16 limit analytics § The tab,
/// item 5).
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

/// What `turnCosts(from:to:)` answers: every turn in the range, oldest first, the name of
/// each chat among them that has one, and when those chats were compacted and prompted.
struct TurnCostLog: Equatable, Sendable {
    var turns: [TurnCost] = []
    /// Chat id → its name: Claude's `ai-title` or first human prompt, or Codex's
    /// `thread_name` or first user prompt. A chat with neither has no entry.
    var titles: [String: String] = [:]
    /// Chat id → when its own context was compacted, oldest first: Claude Code's
    /// `compact_boundary`, Codex's `compacted`. A sub-agent's compaction is not its chat's.
    var compactions: [String: [Date]] = [:]
    /// Chat id → every prompt a person typed in it, oldest first.
    var prompts: [String: [ChatPrompt]] = [:]

    /// The answer of a provider whose log names no chat.
    static let empty = TurnCostLog()

    /// An event's time as the logs keep it: to the whole second, the way the Claude cost
    /// cache writes a date. A transcript read again then finds its own events.
    static func eventTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// One prompt a person typed in a chat: when, and its text collapsed and cut like a
/// chat's name (`SessionTitle.collapse`, `CodexUsageAggregator.promptTitle`). A stretch of
/// the chat is named by the first one typed for it (spec 2026-10-16 limit analytics § The
/// tab, item 5).
struct ChatPrompt: Codable, Comparable, Sendable {
    let at: Date
    let text: String

    static func < (lhs: ChatPrompt, rhs: ChatPrompt) -> Bool {
        lhs.at == rhs.at ? lhs.text < rhs.text : lhs.at < rhs.at
    }
}

extension Array where Element: Comparable {
    /// Puts `value` in its place in this array, which is in ascending order. False, and
    /// nothing changes, when it is already there: a transcript read again repeats its
    /// lines.
    @discardableResult
    mutating func insertKeepingOrder(_ value: Element) -> Bool {
        if let last, last < value {
            append(value)
            return true
        }
        let index = firstIndex { !($0 < value) } ?? endIndex
        if index < endIndex, self[index] == value { return false }
        insert(value, at: index)
        return true
    }
}
