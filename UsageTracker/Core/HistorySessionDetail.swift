import CoreGraphics
import Foundation

/// One token type in an open chat's "Where the money went" (`Dashboard-History-Chats`).
struct HistoryMoneySegment: Equatable, Sendable, Identifiable {
    let category: TokenCategory
    /// "340.8M".
    let tokens: String
    /// "$72.11"; nil for a provider that prices a turn as a whole.
    let cost: String?
    /// This type's part of the chat's dollars, 0…1; 0 when the chat is unpriced.
    let share: Double

    var id: String { category.rawValue }
}

/// The top of an open chat: its dollars split by token type, and the thinking tokens
/// that are part of output (so they carry no dollars of their own).
struct HistoryMoneySplit: Equatable, Sendable {
    let title: String
    /// The chat's dollars beside the title; nil when unpriced, and then no bar is drawn.
    let total: String?
    /// The types with tokens, in `TokenCategory` order (the legend's).
    let segments: [HistoryMoneySegment]
    let thinking: String?

    static let empty = HistoryMoneySplit(title: "", total: nil, segments: [], thinking: nil)

    static func build(_ breakdown: TokenBreakdown) -> HistoryMoneySplit {
        let dollars = breakdown.cost?.total ?? 0
        let priced = dollars > 0
        let segments = TokenCategory.allCases.compactMap { category -> HistoryMoneySegment? in
            let tokens = category.tokens(in: breakdown)
            guard tokens > 0 else { return nil }
            let cost = category.cost(in: breakdown)
            return HistoryMoneySegment(
                category: category,
                tokens: TokenFormat.formatTokens(tokens),
                cost: cost.map { SessionCopy.cost($0) },
                share: priced ? (cost ?? 0) / dollars : 0
            )
        }
        return HistoryMoneySplit(
            title: HistoryCopy.moneyTitle(hasCost: priced),
            total: priced ? SessionCopy.cost(dollars) : nil,
            segments: segments,
            thinking: breakdown.thinking > 0 ? TokenFormat.formatTokens(breakdown.thinking) : nil
        )
    }

    /// The segments laid out in a bar `width` wide with `gap` between them. Every
    /// segment gets `minimum` first and the rest is shared by `shares`, so a 0.04 %
    /// type stays visible and the row is never wider than the bar — the rule
    /// `TokenShareBar.widths` follows, with gaps. The last segment takes exactly what
    /// is left.
    static func widths(shares: [Double], in width: CGFloat, minimum: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard !shares.isEmpty, width > 0 else { return shares.map { _ in 0 } }
        let usable = max(0, width - gap * CGFloat(shares.count - 1))
        let floorWidth = min(minimum, usable / CGFloat(shares.count))
        let remainder = usable - floorWidth * CGFloat(shares.count)
        let total = shares.reduce(0, +)
        var result: [CGFloat] = []
        var used: CGFloat = 0
        for (index, share) in shares.enumerated() {
            let part = total > 0 ? CGFloat(share / total) : 1 / CGFloat(shares.count)
            let w = index == shares.count - 1 ? usable - used : floorWidth + remainder * part
            result.append(w)
            used += w
        }
        return result
    }
}

/// One row of an open chat's sub-agent table, the main thread first.
struct HistoryAgentRow: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// Blank on the main thread: the chat names no model of its own.
    let model: String
    let effort: String
    let turns: String
    let tokens: String
    let cost: String
    let isMain: Bool
}

/// Everything an open chat draws, built once off the main actor per (chat, cap state).
/// The table rows are `SessionDetail`'s — the same sorting, caps and strings 2.7 drew;
/// this adds the share bars, today's day and the money split.
struct HistorySessionDetail: Equatable, Sendable {
    let money: HistoryMoneySplit
    let modelRows: [SessionModelColumns]
    /// Row id → the row's dollars as a share of the chat's most expensive model.
    let modelShares: [String: Double]
    let hiddenModels: Int
    let totalModels: Int
    let dayRows: [SessionDayColumns]
    /// Row id (the day as ISO-8601) → the day's dollars as a share of the chat's
    /// most expensive day.
    let dayShares: [String: Double]
    /// The row drawn in bold: today, when the chat ran today.
    let todayDayID: String?
    let hiddenDays: Int
    let totalDays: Int
    let agentRows: [HistoryAgentRow]
    let hiddenAgents: Int
    let totalAgents: Int

    static let empty = HistorySessionDetail(
        money: .empty, modelRows: [], modelShares: [:], hiddenModels: 0, totalModels: 0,
        dayRows: [], dayShares: [:], todayDayID: nil, hiddenDays: 0, totalDays: 0,
        agentRows: [], hiddenAgents: 0, totalAgents: 0
    )

    static func build(
        session: SessionSummary,
        allAgents: Bool,
        allDays: Bool,
        allModels: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> HistorySessionDetail {
        let base = SessionDetail.build(
            session: session, allAgents: allAgents, allDays: allDays, allModels: allModels,
            calendar: calendar, locale: locale
        )
        let modelMax = session.models.map { $0.tokens.cost?.total ?? 0 }.max() ?? 0
        let modelShares = Dictionary(
            session.models.map { ($0.id, share($0.tokens.cost?.total, max: modelMax)) },
            uniquingKeysWith: { first, _ in first }
        )
        // The same id `SessionCopy.dayColumns` gives a row.
        let iso = ISO8601DateFormatter()
        let dayMax = session.days.map { $0.tokens.cost?.total ?? 0 }.max() ?? 0
        let dayShares = Dictionary(
            session.days.map { (iso.string(from: $0.day), share($0.tokens.cost?.total, max: dayMax)) },
            uniquingKeysWith: { first, _ in first }
        )
        let today = calendar.startOfDay(for: now)
        let todayID = session.days.contains { $0.day == today } ? iso.string(from: today) : nil
        let agentRows = base.agentRows.map { columns in
            let isMain = columns.id == "main"
            return HistoryAgentRow(
                id: columns.id, name: columns.name,
                model: isMain ? "" : columns.model, effort: isMain ? "" : columns.effort,
                turns: columns.turns, tokens: columns.tokens, cost: columns.cost, isMain: isMain
            )
        }
        return HistorySessionDetail(
            money: HistoryMoneySplit.build(session.tokens),
            modelRows: base.modelRows, modelShares: modelShares,
            hiddenModels: base.hiddenModels, totalModels: base.totalModels,
            dayRows: base.dayRows, dayShares: dayShares, todayDayID: todayID,
            hiddenDays: base.hiddenDays, totalDays: base.totalDays,
            agentRows: agentRows, hiddenAgents: base.hiddenAgents, totalAgents: base.totalAgents
        )
    }

    /// `value` as a part of `max`, clamped to 0…1; 0 when either is unknown or zero.
    static func share(_ value: Double?, max: Double) -> Double {
        guard let value, max > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, value / max))
    }
}
