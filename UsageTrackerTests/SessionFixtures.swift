import Foundation
@testable import Omelette

/// `SessionSummary` values built by hand: no aggregator, no log tree, no disk. P1 and
/// P2 test the two aggregators that produce these; everything in P3 is a rule over the
/// value type, so a fixture here states the value and nothing else.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4, § 5.
enum SessionFixture {
    /// Sunday 2026-09-06 11:20:00 UTC — the epoch the rest of this suite pins.
    static let now = Date(timeIntervalSince1970: 1_788_693_600)

    /// UTC and `en_GB`, so a weekday name and a 24-hour clock cannot drift with the
    /// machine the tests run on.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    static let locale = Locale(identifier: "en_GB")

    static func at(hoursBefore hours: Double) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    static func at(daysBefore days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    static func startOfDay(daysBefore days: Int) -> Date {
        calendar.startOfDay(for: now.addingTimeInterval(-Double(days) * 86_400))
    }

    static func tokens(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, thinking: Int = 0,
        cost: TokenCostBreakdown? = nil
    ) -> TokenBreakdown {
        TokenBreakdown(
            input: input, output: output, cacheRead: cacheRead,
            cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h,
            thinking: thinking, cost: cost
        )
    }

    /// A breakdown whose four dollar figures are given exactly, so an assertion on the
    /// total is an equality and not an epsilon.
    static func cost(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) -> TokenCostBreakdown {
        TokenCostBreakdown(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    static func agent(
        id: String,
        kind: String = "executor",
        model: String? = "claude-opus-4-5-20251101",
        effort: String? = "xhigh",
        firstAt: Date? = nil,
        lastAt: Date? = nil,
        turns: Int = 10,
        tokens: TokenBreakdown = SessionFixture.tokens(input: 1_000, output: 100)
    ) -> SessionAgentSummary {
        SessionAgentSummary(
            id: id,
            kind: kind,
            model: model,
            effort: effort,
            firstAt: firstAt ?? at(hoursBefore: 4),
            lastAt: lastAt ?? at(hoursBefore: 3),
            turns: turns,
            tokens: tokens
        )
    }

    static func day(
        daysBefore days: Int,
        turns: Int = 5,
        tokens: TokenBreakdown = SessionFixture.tokens(input: 1_000, output: 100)
    ) -> SessionDaySummary {
        SessionDaySummary(day: startOfDay(daysBefore: days), turns: turns, tokens: tokens)
    }

    /// `mainTokens` defaults to `tokens`: a chat with no sub-agents spent all of it on
    /// its own thread, which is what both aggregators report.
    static func session(
        id: String,
        providerID: String = "claude",
        title: String? = nil,
        projectSlug: String = "-Users-tester-Projects-alpha",
        origin: String? = nil,
        firstAt: Date? = nil,
        lastAt: Date? = nil,
        turns: Int = 12,
        tokens: TokenBreakdown = SessionFixture.tokens(input: 1_000, output: 100),
        mainTokens: TokenBreakdown? = nil,
        agents: [SessionAgentSummary] = [],
        days: [SessionDaySummary] = []
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            providerID: providerID,
            title: title,
            projectSlug: projectSlug,
            origin: origin,
            firstAt: firstAt ?? at(hoursBefore: 6),
            lastAt: lastAt ?? at(hoursBefore: 1),
            turns: turns,
            tokens: tokens,
            mainTokens: mainTokens ?? tokens,
            agents: agents,
            days: days
        )
    }

    /// The shape `SessionListRule` needs and nothing more: it reads `lastAt`,
    /// `tokens.cost` and `id`.
    static func simple(
        id: String, hoursAgo: Double, cost dollars: Double, providerID: String = "claude"
    ) -> SessionSummary {
        session(
            id: id,
            providerID: providerID,
            lastAt: at(hoursBefore: hoursAgo),
            tokens: tokens(input: 1_000, output: 100, cost: cost(input: dollars))
        )
    }
}
