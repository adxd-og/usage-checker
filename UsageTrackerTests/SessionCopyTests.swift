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
