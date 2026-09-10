import XCTest
@testable import Omelette

/// Independent verification of `SessionCopy` (both halves) against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4, and the orchestrator
/// rulings this package is judged against: time strings follow `ResetCopy.absolute`'s
/// ladder with an unpadded hour under en_GB, and the sub-agent/day tables are capped at
/// 8 and 14 respectively. Written from the spec, not from `SessionCopyTests` — this file
/// pins the exact day-6/day-7 boundary of the "this week" ladder, the zero-thinking
/// omission by name, the "$0.00" vs "—" distinction on a chat priced at exactly zero,
/// and the SessionDetail-level 9-agent and 15-day boundaries the rule-level tests don't
/// reach.
final class SessionCopyVerificationTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }

    // MARK: - The exact boundary of "this week"

    /// § 4 / `SessionCopy.lastActive`: a weekday name inside the last six days, a date
    /// beyond it. Six days back is Monday 31 Aug (still a weekday); seven days back is
    /// Sunday 30 Aug (a date). Both `SessionCopyTests` fixtures (4 and 8 days) sit well
    /// inside each side of this line — this test sits exactly on it.
    func testTheWeekdayLadderSwitchesToADateExactlyAtSevenDaysNotBefore() {
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 6), now: now, calendar: calendar, locale: locale),
            "Mon 11:20",
            "six days back is still inside the weekday window"
        )
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 7), now: now, calendar: calendar, locale: locale),
            "30 Aug",
            "seven days back is where the weekday ladder ends"
        )
    }

    // MARK: - The split line's thinking term

    /// The design's own example line always shows a non-zero thinking figure. The rule
    /// must not print "Thinking 0" for a chat that reported none — omit the term
    /// entirely, the same way an empty bucket is dropped from the rest of the line.
    func testTheSplitLineOmitsThinkingByNameWhenThereIsNone() {
        let breakdown = SessionFixture.tokens(
            input: 1_000, output: 500, cacheRead: 200,
            cost: SessionFixture.cost(input: 1, output: 2, cacheRead: 3)
        )

        let line = SessionCopy.splitLine(breakdown)

        XCTAssertEqual(line, "Input 1.0k ($1.00) · Output 500 ($2.00) · Cache read 200 ($3.00)")
        XCTAssertFalse(line.contains("Thinking"), "zero thinking is omitted, never printed as \"Thinking 0\"")
    }

    // MARK: - "$0.00" is not "—"

    /// A chat priced at exactly zero and a chat with no split at all must read
    /// differently: one has a real answer ("nothing"), the other has no answer at all.
    func testAPricedZeroCostChatReadsDollarsWhileAnUnpricedOneReadsADash() {
        let priced = SessionFixture.session(
            id: "priced",
            tokens: SessionFixture.tokens(input: 100, cost: TokenCostBreakdown())
        )
        let unpriced = SessionFixture.session(
            id: "unpriced",
            tokens: SessionFixture.tokens(input: 100)
        )

        XCTAssertEqual(SessionCopy.cost(priced.tokens.cost?.total), "$0.00")
        XCTAssertEqual(SessionCopy.cost(unpriced.tokens.cost?.total), "—")
        // Both rank identically as zero — the list must not invent a number either way.
        XCTAssertEqual(SessionListRule.cost(of: priced), 0)
        XCTAssertEqual(SessionListRule.cost(of: unpriced), 0)
    }

    // MARK: - A project slug the decoder cannot make sense of

    /// Codex's slug is a percent-encoded absolute path; a string that is neither
    /// percent-encoded content nor an absolute path is handed back verbatim rather than
    /// guessed at (`ProjectName.decode(encodedPath:)`).
    func testACodexSlugThatIsNotAnAbsolutePathIsReturnedVerbatim() {
        XCTAssertEqual(SessionCopy.projectName(providerID: "codex", projectSlug: "banana"), "banana")
        // Contrast: a real percent-encoded absolute path does decode.
        XCTAssertEqual(
            SessionCopy.projectName(providerID: "codex", projectSlug: "%2FUsers%2Ftester%2FProjects%2Falpha"),
            "Projects / alpha"
        )
    }

    // MARK: - Empty hint is Codex-only, never a guess for anything else

    func testTheEmptyHintNamesOnlyCodexAndNothingElse() {
        XCTAssertEqual(SessionCopy.emptyHint(providerID: "codex"), "Codex writes session logs from 0.146 on")
        XCTAssertNil(SessionCopy.emptyHint(providerID: "claude"))
        XCTAssertNil(SessionCopy.emptyHint(providerID: "grok"), "a provider with no session log at all gets no hint here either")
        XCTAssertNil(SessionCopy.emptyHint(providerID: ""))
    }

    // MARK: - SessionDetail at the exact agent/day cap boundaries

    private func session(agents: Int, days: Int) -> SessionSummary {
        SessionFixture.session(
            id: "s1",
            agents: (1...max(agents, 1)).prefix(agents).map {
                SessionFixture.agent(
                    id: "a\($0)",
                    tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: Double($0)))
                )
            },
            days: (0..<days).map { SessionFixture.day(daysBefore: days - 1 - $0) }
        )
    }

    func testSessionDetailAtExactlyEightAgentsDrawsAllOfThemWithNothingHidden() {
        let detail = SessionDetail.build(session: session(agents: 8, days: 0), allAgents: false, allDays: false, calendar: calendar, locale: locale)
        XCTAssertEqual(detail.agentRows.count, 9, "Main thread plus all eight")
        XCTAssertEqual(detail.hiddenAgents, 0)
        XCTAssertEqual(detail.totalAgents, 8)
    }

    func testSessionDetailAtNineAgentsHidesExactlyOne() {
        let detail = SessionDetail.build(session: session(agents: 9, days: 0), allAgents: false, allDays: false, calendar: calendar, locale: locale)
        XCTAssertEqual(detail.agentRows.count, 9, "Main thread plus the eight most expensive")
        XCTAssertEqual(detail.hiddenAgents, 1)
        XCTAssertEqual(detail.totalAgents, 9)
    }

    func testSessionDetailWithNoAgentsHasNoAgentTableAndNoHiddenCount() {
        let detail = SessionDetail.build(session: session(agents: 0, days: 0), allAgents: false, allDays: false, calendar: calendar, locale: locale)
        XCTAssertTrue(detail.agentRows.isEmpty)
        XCTAssertEqual(detail.hiddenAgents, 0)
        XCTAssertEqual(detail.totalAgents, 0)
    }

    func testSessionDetailAtFifteenDaysHidesExactlyTheOldestOne() {
        let detail = SessionDetail.build(session: session(agents: 0, days: 15), allAgents: false, allDays: false, calendar: calendar, locale: locale)
        XCTAssertEqual(detail.dayRows.count, 14)
        XCTAssertEqual(detail.hiddenDays, 1)
        XCTAssertEqual(detail.totalDays, 15)
        XCTAssertEqual(
            detail.dayRows.first?.day,
            SessionCopy.dayText(SessionFixture.startOfDay(daysBefore: 13), calendar: calendar, locale: locale),
            "the oldest surviving day is the 14th most recent, not the 15th"
        )
    }
}
