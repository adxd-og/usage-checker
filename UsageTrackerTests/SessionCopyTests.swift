import XCTest
@testable import Omelette

/// Every string History's Sessions list, `status.json` and `get_sessions` put in front
/// of a person — the half that takes primitives and is compiled into the `omelette`
/// binary as well as the app, so the terminal and the dashboard cannot spell the same
/// chat two ways.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4, § 5.
final class SessionCopyTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }

    // MARK: - The row's title

    func testAChatWithNoNameFallsBackToItsProjectAndFirstDay() {
        XCTAssertEqual(
            SessionCopy.rowTitle(
                title: nil, project: "Usage tracker",
                firstAt: SessionFixture.at(daysBefore: 3),
                calendar: calendar, locale: locale
            ),
            "Usage tracker · 3 Sep"
        )
    }

    func testABlankNameIsNoNameAtAll() {
        // A first prompt that was nothing but whitespace must not produce an empty row.
        XCTAssertEqual(
            SessionCopy.rowTitle(
                title: "   \n", project: "Usage tracker",
                firstAt: SessionFixture.at(daysBefore: 3),
                calendar: calendar, locale: locale
            ),
            "Usage tracker · 3 Sep"
        )
    }

    func testAChatWithANameKeepsIt() {
        XCTAssertEqual(
            SessionCopy.rowTitle(
                title: "Интеграция Blume", project: "Usage tracker",
                firstAt: SessionFixture.at(daysBefore: 3),
                calendar: calendar, locale: locale
            ),
            "Интеграция Blume"
        )
    }

    // MARK: - When it was last active

    func testLastActiveIsTodayThenAWeekdayThenADate() {
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(hoursBefore: 3), now: now, calendar: calendar, locale: locale),
            "Today 8:20"
        )
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 4), now: now, calendar: calendar, locale: locale),
            "Wed 11:20",
            "inside the last six days the weekday places it"
        )
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 8), now: now, calendar: calendar, locale: locale),
            "29 Aug",
            "past a week the minute stops mattering"
        )
    }

    func testTheSentenceStyleLowercasesOnlyToday() {
        // "Claude · … · today 8:20 · …" is a sentence; "Today 8:20" is a column.
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(hoursBefore: 3), now: now, style: .sentence, calendar: calendar, locale: locale),
            "today 8:20"
        )
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 4), now: now, style: .sentence, calendar: calendar, locale: locale),
            "Wed 11:20",
            "a weekday is a name in either style"
        )
        XCTAssertEqual(
            SessionCopy.lastActive(SessionFixture.at(daysBefore: 8), now: now, style: .sentence, calendar: calendar, locale: locale),
            "29 Aug"
        )
    }

    // MARK: - Counts

    func testTurnsAndSubAgentsPluralise() {
        XCTAssertEqual(SessionCopy.turns(1), "1 turn")
        XCTAssertEqual(SessionCopy.turns(356), "356 turns")
        XCTAssertEqual(SessionCopy.turns(0), "0 turns")

        XCTAssertNil(SessionCopy.subAgents(0), "a chat that launched none says nothing")
        XCTAssertEqual(SessionCopy.subAgents(1), "1 sub-agent")
        XCTAssertEqual(SessionCopy.subAgents(3), "3 sub-agents")
        XCTAssertEqual(SessionCopy.subAgentsTitle(count: 3), "Sub-agents (3)")
    }

    // MARK: - Chips

    func testOnlyAnExecOriginGetsAChip() {
        // A Codex chat Claude drove is worth telling apart from one the user typed;
        // a chip on every row would say nothing.
        XCTAssertEqual(SessionCopy.originChip("codex_exec"), "exec")
        XCTAssertNil(SessionCopy.originChip("codex-tui"))
        XCTAssertNil(SessionCopy.originChip("codex_work_desktop"))
        XCTAssertNil(SessionCopy.originChip(nil), "Claude reports no origin at all")
    }

    func testTheTopSpendChipIsTheSpecsTwoWords() {
        XCTAssertEqual(SessionCopy.topSpendChip, "top spend")
    }

    // MARK: - Dollars

    func testCostSpellsDollarsTheWayEveryOtherRowDoes() {
        XCTAssertEqual(SessionCopy.cost(58.1), "$58.10")
        XCTAssertEqual(SessionCopy.cost(0), "$0.00")
        XCTAssertEqual(SessionCopy.cost(nil), "—", "a provider that prices a turn as a whole gets no invented split")
    }

    // MARK: - The list's own chrome

    func testTheListHeaderSaysHowManyOfHowMany() {
        XCTAssertEqual(SessionCopy.listHeader(shown: 15, total: 34), "15 of 34 chats")
        XCTAssertEqual(SessionCopy.listHeader(shown: 4, total: 4), "4 chats")
        XCTAssertEqual(SessionCopy.listHeader(shown: 1, total: 1), "1 chat")
    }

    /// Without a header the three figures on a chat row are unlabelled digits. The
    /// titles are the row's own columns, in the row's order: the chat, then the four
    /// values the wide row draws to its right.
    func testTheColumnTitlesNameEveryFigureOnAChatRow() {
        XCTAssertEqual(
            SessionCopy.listColumns,
            ["Chat", "Last active", "Turns", "Tokens", "Cost"]
        )
        XCTAssertEqual(SessionCopy.listColumns.first, "Chat", "the title column comes first, as on the row")
        XCTAssertEqual(
            SessionCopy.listColumns.count, 1 + 4,
            "the title column plus the four values the row draws: last active, turns, tokens, cost"
        )
    }

    func testTheShowAllButtonNamesTheNumberAndTheWayBack() {
        XCTAssertEqual(SessionCopy.showAll(count: 34, expanded: false), "Show all 34")
        XCTAssertEqual(SessionCopy.showAll(count: 34, expanded: true), "Show fewer")
    }

    /// The two caps inside an expanded chat name what they are hiding, because "Show
    /// all 1235" under a table of eight rows says nothing about what those 1235 are.
    func testTheTwoInnerButtonsNameWhatTheyAreHiding() {
        XCTAssertEqual(SessionCopy.showAllAgents(count: 1_235, expanded: false), "Show all 1235 sub-agents")
        XCTAssertEqual(SessionCopy.showAllAgents(count: 1, expanded: false), "Show all 1 sub-agent")
        XCTAssertEqual(SessionCopy.showAllAgents(count: 1_235, expanded: true), "Show fewer")
        XCTAssertEqual(SessionCopy.showAllDays(count: 92, expanded: false), "Show all 92 days")
        XCTAssertEqual(SessionCopy.showAllDays(count: 1, expanded: false), "Show all 1 day")
        XCTAssertEqual(SessionCopy.showAllDays(count: 92, expanded: true), "Show fewer")
    }
}

/// The three sections of an expanded chat — the token split, the sub-agent table and
/// the by-day table — plus the project name and the empty state. Same enum as above,
/// app-target half: these rules read `SessionSummary` and `TokenBreakdown`.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4.
final class SessionCopySummaryTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let locale = SessionFixture.locale

    // MARK: - (a) The split line

    func testTheSplitLineNamesEveryBucketThatHasTokensAndItsDollars() {
        let breakdown = SessionFixture.tokens(
            input: 1_200_000, output: 340_000, cacheRead: 18_000_000,
            cacheWrite5m: 2_100_000, thinking: 90_000,
            cost: SessionFixture.cost(input: 3.60, output: 5.10, cacheRead: 5.40, cacheWrite: 7.88)
        )

        XCTAssertEqual(
            SessionCopy.splitLine(breakdown),
            "Input 1.2M ($3.60) · Output 340.0k ($5.10) · Cache read 18.0M ($5.40) · Cache write 2.1M ($7.88) · Thinking 90.0k"
        )
    }

    func testThinkingCarriesNoDollarsOfItsOwn() {
        // It is a slice of output; pricing it again would double-count the same money.
        let line = SessionCopy.splitLine(SessionFixture.tokens(
            output: 1_000, thinking: 400, cost: SessionFixture.cost(output: 2)
        ))
        XCTAssertEqual(line, "Output 1.0k ($2.00) · Thinking 400")
    }

    func testAnEmptyBucketIsNotAColumnOfZeroes() {
        XCTAssertEqual(SessionCopy.splitLine(SessionFixture.tokens(input: 5)), "Input 5")
        XCTAssertEqual(SessionCopy.splitLine(.zero), "", "nothing to say and nothing said")
    }

    func testAnUnpricedProviderShowsCountsAndNoDollars() {
        XCTAssertEqual(
            SessionCopy.splitLine(SessionFixture.tokens(input: 2_000, output: 500)),
            "Input 2.0k · Output 500"
        )
    }

    // MARK: - (b) The sub-agent table

    func testTheMainThreadRowIsWhatTheChatSpentWithoutItsAgents() {
        let agent = SessionFixture.agent(
            id: "a1", turns: 20,
            tokens: SessionFixture.tokens(input: 500_000, cost: SessionFixture.cost(input: 4))
        )
        let session = SessionFixture.session(
            id: "s1", turns: 56,
            tokens: SessionFixture.tokens(input: 2_000_000, cost: SessionFixture.cost(input: 16)),
            mainTokens: SessionFixture.tokens(input: 1_500_000, cost: SessionFixture.cost(input: 12)),
            agents: [agent]
        )

        let main = SessionCopy.mainThreadColumns(session)

        XCTAssertEqual(main.name, "Main thread")
        XCTAssertEqual(main.turns, "36", "56 turns minus the agent's 20")
        XCTAssertEqual(main.tokens, "1.5M")
        XCTAssertEqual(main.cost, "$12.00")
        XCTAssertEqual(main.model, "—", "the summary carries no model for the chat itself")
        XCTAssertEqual(main.effort, "—")
    }

    func testTheMainThreadNeverShowsNegativeTurns() {
        // A clipped range can leave an agent whose turns outnumber the days that
        // survived the clip; a "-4" in the table would read as a bug in the log.
        let agent = SessionFixture.agent(id: "a1", turns: 40)
        let session = SessionFixture.session(id: "s1", turns: 10, agents: [agent])

        XCTAssertEqual(SessionCopy.mainThreadTurns(session), 0)
    }

    func testASubAgentRowShortensTheModelName() {
        let agent = SessionFixture.agent(
            id: "a1", kind: "executor", model: "claude-opus-4-5-20251101", effort: "xhigh",
            turns: 12, tokens: SessionFixture.tokens(input: 900_000, cost: SessionFixture.cost(input: 7.5))
        )

        XCTAssertEqual(
            SessionCopy.agentColumns(agent),
            SessionColumns(
                id: "a1", name: "executor", model: "Opus 4.5", effort: "xhigh",
                turns: "12", tokens: "900.0k", cost: "$7.50"
            )
        )
    }

    func testAnAgentWithNoModelOrEffortShowsADashRatherThanAGuess() {
        let agent = SessionFixture.agent(id: "a1", kind: "Bacon", model: nil, effort: nil, turns: 3)
        let columns = SessionCopy.agentColumns(agent)

        XCTAssertEqual(columns.name, "Bacon")
        XCTAssertEqual(columns.model, "—")
        XCTAssertEqual(columns.effort, "—")
        XCTAssertEqual(columns.cost, "—", "no split, no dollars")
    }

    // MARK: - (c) The by-day table

    func testTheDayRowNamesTheDayInTheUsersSpelling() {
        let day = SessionFixture.day(
            daysBefore: 3, turns: 12,
            tokens: SessionFixture.tokens(input: 4_200_000, cost: SessionFixture.cost(input: 4.2))
        )

        XCTAssertEqual(
            SessionCopy.dayColumns(day, calendar: calendar, locale: locale),
            SessionDayColumns(
                id: ISO8601DateFormatter().string(from: SessionFixture.startOfDay(daysBefore: 3)),
                day: "3 Sep", turns: "12", tokens: "4.2M", cost: "$4.20"
            )
        )
    }

    func testTheSectionTitlesAreTheSpecs() {
        XCTAssertEqual(SessionCopy.byDayTitle, "By day")
        XCTAssertEqual(SessionCopy.subAgentsTitle(count: 2), "Sub-agents (2)")
    }

    // MARK: - (d) The by-model table

    func testAModelRowShortensTheNameAndKeepsTheEffort() {
        let row = SessionFixture.model(
            model: "claude-opus-4-5-20251101", effort: "xhigh", turns: 12,
            tokens: SessionFixture.tokens(input: 900_000, cost: SessionFixture.cost(input: 7.5))
        )

        XCTAssertEqual(
            SessionCopy.modelColumns(row),
            SessionModelColumns(
                id: "claude-opus-4-5-20251101|xhigh", model: "Opus 4.5", effort: "xhigh",
                turns: "12", tokens: "900.0k", cost: "$7.50"
            )
        )
    }

    func testAModelWithNoEffortCarriesNoLabelRatherThanADash() {
        // The effort rides beside the model name, so "nothing to say" is nothing drawn;
        // the sub-agent table's fixed-width column is the one that needs a dash.
        let columns = SessionCopy.modelColumns(
            SessionFixture.model(model: "gpt-5.6-terra", effort: nil, turns: 3)
        )

        XCTAssertNil(columns.effort)
        XCTAssertEqual(columns.id, "gpt-5.6-terra|")
        XCTAssertEqual(columns.turns, "3")
    }

    func testAnUnpricedModelRowShowsCountsAndNoDollars() {
        XCTAssertEqual(
            SessionCopy.modelColumns(SessionFixture.model(effort: "high", turns: 2)).cost,
            "—"
        )
    }

    func testAModelIdWithNoDisplayNameIsItsOwnName() {
        // ModelPricing answers nil for a synthetic id; the row shows what the log wrote
        // rather than an empty cell.
        XCTAssertEqual(
            SessionCopy.modelColumns(
                SessionFixture.model(model: "<synthetic>", effort: nil)
            ).model,
            "<synthetic>"
        )
    }

    func testTheByModelTitleAndColumnsAreTheSpecs() {
        XCTAssertEqual(SessionCopy.byModelTitle, "By model")
        XCTAssertEqual(SessionCopy.modelColumnTitles, ["Model", "Turns", "Tokens", "Cost"])
    }

    func testTheShowAllModelsButtonNamesWhatItIsHiding() {
        XCTAssertEqual(SessionCopy.showAllModels(count: 9, expanded: false), "Show all 9 models")
        XCTAssertEqual(SessionCopy.showAllModels(count: 1, expanded: false), "Show all 1 model")
        XCTAssertEqual(SessionCopy.showAllModels(count: 9, expanded: true), "Show fewer")
    }

    // MARK: - The whole expanded row, built once

    private func bigChat(agents: Int, days: Int) -> SessionSummary {
        SessionFixture.session(
            id: "s1", title: "Blume integration",
            turns: 4_000,
            tokens: SessionFixture.tokens(input: 40_000_000, cost: SessionFixture.cost(input: 400)),
            mainTokens: SessionFixture.tokens(input: 10_000_000, cost: SessionFixture.cost(input: 100)),
            agents: (1...max(1, agents)).map {
                SessionFixture.agent(
                    id: String(format: "a%04d", $0), turns: 2,
                    tokens: SessionFixture.tokens(input: 1_000, cost: SessionFixture.cost(input: Double($0)))
                )
            },
            days: (0..<days).map { SessionFixture.day(daysBefore: days - 1 - $0) }
        )
    }

    func testAChatWithAThousandAgentsDrawsNineRowsAndCountsThemAll() {
        // 1,235 sub-agents is a real chat on this Mac. The header says 1235, the table
        // draws Main thread plus the eight most expensive, and the button offers the rest.
        let detail = SessionDetail.build(
            session: bigChat(agents: 1_235, days: 3),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.agentsTitle, "Sub-agents (1235)", "the header is never the capped count")
        XCTAssertEqual(detail.totalAgents, 1_235)
        XCTAssertEqual(detail.agentRows.count, 9, "Main thread plus eight")
        XCTAssertEqual(detail.agentRows.first?.name, "Main thread")
        XCTAssertEqual(detail.agentRows.dropFirst().first?.name, "executor")
        XCTAssertEqual(detail.agentRows.dropFirst().first?.cost, "$1235.00", "most expensive first")
        XCTAssertEqual(detail.hiddenAgents, 1_227)
    }

    func testAskingForAllOfThemGivesAllOfThem() {
        let detail = SessionDetail.build(
            session: bigChat(agents: 1_235, days: 3),
            allAgents: true, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.agentRows.count, 1_236, "Main thread plus every agent")
        XCTAssertEqual(detail.hiddenAgents, 0)
    }

    func testAChatWithNoAgentsHasNoAgentTableAtAll() {
        let detail = SessionDetail.build(
            session: SessionFixture.session(id: "s1"),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertTrue(detail.agentRows.isEmpty, "a Main thread row alone is a table about nothing")
        XCTAssertEqual(detail.totalAgents, 0)
        XCTAssertEqual(detail.hiddenAgents, 0)
    }

    private func manyModelChat(models count: Int) -> SessionSummary {
        SessionFixture.session(
            id: "s1", title: "Blume integration", turns: 40,
            tokens: SessionFixture.tokens(input: 4_000_000, cost: SessionFixture.cost(input: 40)),
            models: (1...count).map {
                SessionFixture.model(
                    model: "model-\($0)", effort: "high", turns: 2,
                    tokens: SessionFixture.tokens(
                        input: 1_000, cost: SessionFixture.cost(input: Double($0))
                    )
                )
            }
        )
    }

    func testAChatOnSevenModelsDrawsSixRowsAndCountsThemAll() {
        let detail = SessionDetail.build(
            session: manyModelChat(models: 7),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.modelRows.count, 6)
        XCTAssertEqual(detail.modelRows.first?.cost, "$7.00", "most expensive first")
        XCTAssertEqual(detail.hiddenModels, 1)
        XCTAssertEqual(detail.totalModels, 7, "the header count is never the capped one")
    }

    func testAskingForAllModelsGivesAllOfThem() {
        let detail = SessionDetail.build(
            session: manyModelChat(models: 7),
            allAgents: false, allDays: false, allModels: true,
            calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.modelRows.count, 7)
        XCTAssertEqual(detail.hiddenModels, 0)
    }

    func testAChatOnOneModelWithNoEffortHasNoModelTableAtAll() {
        let detail = SessionDetail.build(
            session: SessionFixture.session(
                id: "s1", models: [SessionFixture.model(model: "claude-opus-4-5", effort: nil)]
            ),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertTrue(detail.modelRows.isEmpty, "the split line above already says all of it")
        XCTAssertEqual(detail.hiddenModels, 0)
        XCTAssertEqual(detail.totalModels, 1, "hidden is not the same as absent")
    }

    func testANinetyDayChatDrawsFourteenDaysAndCountsThemAll() {
        let detail = SessionDetail.build(
            session: bigChat(agents: 2, days: 90),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertEqual(detail.totalDays, 90)
        XCTAssertEqual(detail.dayRows.count, 14)
        XCTAssertEqual(detail.hiddenDays, 76)
        XCTAssertEqual(detail.dayRows.last?.day, SessionCopy.dayText(SessionFixture.startOfDay(daysBefore: 0), calendar: calendar, locale: locale))
    }

    func testASingleDayChatHasNoByDayTable() {
        // § 4: the table appears only when `days.count > 1` — one row repeating the
        // headline is not a breakdown.
        let detail = SessionDetail.build(
            session: bigChat(agents: 1, days: 1),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )

        XCTAssertTrue(detail.dayRows.isEmpty)
        XCTAssertEqual(detail.hiddenDays, 0)
    }

    func testTheSplitLineIsCarriedByTheBuiltDetail() {
        let detail = SessionDetail.build(
            session: bigChat(agents: 1, days: 2),
            allAgents: false, allDays: false, calendar: calendar, locale: locale
        )
        XCTAssertEqual(detail.split, SessionCopy.splitLine(bigChat(agents: 1, days: 2).tokens))
        XCTAssertEqual(SessionDetail.empty.split, "")
    }

    // MARK: - The project, per provider

    func testTheProjectNameFollowsTheProvidersOwnSlugShape() {
        // Claude's dash slug is lossy and resolved against the filesystem; Codex's is a
        // percent-encoded absolute path and is not. Both must read the same way.
        XCTAssertEqual(
            SessionCopy.projectName(providerID: "claude", projectSlug: "-Users-tester-Projects-alpha"),
            "Projects / alpha"
        )
        XCTAssertEqual(
            SessionCopy.projectName(providerID: "codex", projectSlug: "%2FUsers%2Ftester%2FProjects%2Falpha"),
            "Projects / alpha"
        )
    }

    func testTheRowTitleOfASummaryUsesTheDecodedProject() {
        let session = SessionFixture.session(
            id: "s1", title: nil, projectSlug: "-Users-tester-Projects-alpha",
            firstAt: SessionFixture.at(daysBefore: 3)
        )

        XCTAssertEqual(
            SessionCopy.rowTitle(session, calendar: calendar, locale: locale),
            "Projects / alpha · 3 Sep"
        )
    }

    // MARK: - Empty

    func testTheEmptyStateOnlyWarnsCodexUsersAboutOldVersions() {
        XCTAssertEqual(SessionCopy.emptyTitle, "No chats in this period")
        XCTAssertEqual(SessionCopy.emptyHint(providerID: "codex"), "Codex writes session logs from 0.146 on")
        XCTAssertNil(SessionCopy.emptyHint(providerID: "claude"), "Claude Code has always written them")
    }
}
