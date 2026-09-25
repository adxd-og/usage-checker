import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, the History rows: the page is "History", and one line
/// under the title says where its numbers come from. On a subscription that line is
/// also where the dollars are called API-equivalent, once for the page (CLAUDE.md,
/// Conventions).
final class HistoryCopySubtitleTests: XCTestCase {
    func testThePageIsCalledHistory() {
        XCTAssertEqual(HistoryCopy.title, "History")
    }

    func testASubscriptionsDollarsAreCalledApiEquivalentOnce() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Claude",
                sourceName: "Claude Code's session logs", isPayAsYouGo: false
            ),
            "API-equivalent cost from Claude Code's session logs, not your subscription bill"
        )
    }

    func testPayAsYouGoDollarsAreTheBill() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Claude",
                sourceName: "Claude Code's session logs", isPayAsYouGo: true
            ),
            "Cost from Claude Code's session logs"
        )
    }

    func testALogWithNoNameStillReadsAsASentence() {
        XCTAssertEqual(
            HistoryCopy.subtitle(showsQuota: false, providerName: "Grok", sourceName: nil, isPayAsYouGo: false),
            "API-equivalent cost from local CLI logs, not your subscription bill"
        )
    }

    func testAQuotaOnlyProviderIsAboutHowFullItsWindowsRan() {
        for isPayAsYouGo in [false, true] {
            XCTAssertEqual(
                HistoryCopy.subtitle(
                    showsQuota: true, providerName: "Antigravity",
                    sourceName: nil, isPayAsYouGo: isPayAsYouGo
                ),
                "How full Antigravity usage windows ran"
            )
        }
    }

    func testTheCodexLogIsNamedTheWayCostSourceNamesIt() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Codex",
                sourceName: DashboardState.costSource(for: "codex").longName, isPayAsYouGo: false
            ),
            "API-equivalent cost from the Codex CLI's session logs, not your subscription bill"
        )
    }
}

/// The Cost/Tokens switch names itself for VoiceOver; the control's default is "Provider".
final class HistoryCopyControlsTests: XCTestCase {
    func testTheUnitSwitchIsCalledUnit() {
        XCTAssertEqual(HistoryCopy.modePickerLabel, "Unit")
    }
}

/// The Sessions card's words (`Dashboard-History-Cost`, `-Chats`). The 2.x "top spend"
/// and "exec" chips become words on the project line (spec § Principles 2).
final class HistoryCopySessionsTests: XCTestCase {
    func testTheCardIsCalledSessions() {
        XCTAssertEqual(HistoryCopy.sessionsTitle, "Sessions")
    }

    func testACutListSaysHowManyOfHowMany() {
        XCTAssertEqual(HistoryCopy.sessionCount(shown: 4, total: 103), "4 of 103")
        XCTAssertEqual(HistoryCopy.sessionCount(shown: 15, total: 1_204), "15 of 1,204")
    }

    func testAWholeListIsJustItsCount() {
        XCTAssertEqual(HistoryCopy.sessionCount(shown: 7, total: 7), "7")
    }

    func testTheColumnsAreTheMockupsFive() {
        XCTAssertEqual(HistoryCopy.sessionColumns, ["Session", "Last active", "Turns", "Tokens", "Cost"])
    }

    func testCountsAreGroupedTheWayTheDollarsAre() {
        XCTAssertEqual(HistoryCopy.count(1_729), "1,729")
        XCTAssertEqual(HistoryCopy.count(2), "2")
    }

    func testTheProjectLineCarriesWhatTheChipsUsedToSay() {
        XCTAssertEqual(HistoryCopy.sessionSubtitle(project: "Usage tracker", isTop: false, origin: nil), "Usage tracker")
        XCTAssertEqual(HistoryCopy.sessionSubtitle(project: "Usage tracker", isTop: true, origin: nil), "Usage tracker · top spend")
        XCTAssertEqual(HistoryCopy.sessionSubtitle(project: "alpha", isTop: true, origin: "codex_exec"), "alpha · top spend · exec")
        XCTAssertEqual(HistoryCopy.sessionSubtitle(project: "alpha", isTop: false, origin: "codex-tui"), "alpha")
    }

    func testANarrowRowFoldsItsFiguresIntoOneCaption() {
        XCTAssertEqual(
            HistoryCopy.narrowCaption(lastActive: "Today 14:05", turns: 1_729, tokens: 350_900_000),
            "Today 14:05 · 1,729 turns · 350.9M tokens"
        )
        XCTAssertEqual(
            HistoryCopy.narrowCaption(lastActive: "Tue 09:12", turns: 1, tokens: 800),
            "Tue 09:12 · 1 turn · 800 tokens"
        )
    }

    func testTheSortSwitchIsCalledSort() {
        XCTAssertEqual(HistoryCopy.sortPickerLabel, "Sort")
    }
}

/// An open chat's words (`Dashboard-History-Chats`).
final class HistoryCopyOpenChatTests: XCTestCase {
    func testThePanelsWordsAreTheMockups() {
        XCTAssertEqual(HistoryCopy.moneyTitle(hasCost: true), "Where the money went")
        XCTAssertEqual(HistoryCopy.moneyTitle(hasCost: false), "Tokens by type")
        XCTAssertEqual(HistoryCopy.thinkingLabel, "Thinking")
        XCTAssertEqual(HistoryCopy.thinkingNote, "in output")
        XCTAssertEqual(HistoryCopy.subAgentsTitle, "Sub-agents")
        XCTAssertEqual(HistoryCopy.agentColumns, ["Agent", "Model", "Effort", "Turns", "Tokens", "Cost"])
        XCTAssertEqual(HistoryCopy.dayColumns, ["Day", "Turns", "Tokens", "Cost"])
    }

    func testANarrowAgentRowFoldsItsColumnsIntoACaption() {
        let agent = HistoryAgentRow(
            id: "x", name: "planner", model: "Opus 5.5", effort: "xhigh",
            turns: "87", tokens: "31.9M", cost: "$15.37", isMain: false
        )
        XCTAssertEqual(HistoryCopy.agentCaption(agent), "Opus 5.5 · xhigh · 87 turns · 31.9M")
        let main = HistoryAgentRow(
            id: "main", name: "Main thread", model: "", effort: "",
            turns: "282", tokens: "80.9M", cost: "$65.89", isMain: true
        )
        XCTAssertEqual(HistoryCopy.agentCaption(main), "282 turns · 80.9M")
    }
}

/// The chart card's words and figures (`Dashboard-History-Cost`, `-Tokens`).
final class HistoryCopyChartTests: XCTestCase {
    func testTheCardIsNamedForItsUnit() {
        XCTAssertEqual(HistoryCopy.chartTitle(mode: .cost), "Cost per day")
        XCTAssertEqual(HistoryCopy.chartTitle(mode: .tokens), "Tokens per day")
    }

    func testTheCostCardsHeaderIsTheDayCountAndTheRangesTotal() {
        XCTAssertEqual(HistoryCopy.chartSummary(HistoryRangeSummary(dayCount: 7, cost: 3_245.6, activeDays: 7)), "7 days · $3,245.60")
        XCTAssertEqual(HistoryCopy.chartSummary(HistoryRangeSummary(dayCount: 1, cost: 0, activeDays: 0)), "1 day · $0.00")
        XCTAssertEqual(HistoryCopy.chartSummary(HistoryRangeSummary(dayCount: 365, cost: 12_884.93, activeDays: 49)), "365 days · $12,884.93")
    }

    func testDollarsAreGroupedWithTwoDecimals() {
        XCTAssertEqual(HistoryCopy.dollars(1_352.28), "$1,352.28")
        XCTAssertEqual(HistoryCopy.dollars(0.07), "$0.07")
    }

    func testTheCostAxisPrintsWholeDollarsWhereItCan() {
        XCTAssertEqual(HistoryCopy.costAxisLabel(0), "$0")
        XCTAssertEqual(HistoryCopy.costAxisLabel(1_500), "$1,500")
        XCTAssertEqual(HistoryCopy.costAxisLabel(0.5), "$0.50")
    }

    func testTheTokenAxisPrintsMillionsWithoutAFractionWhereItCan() {
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(0), "0")
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(500_000_000), "500M")
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(1_000_000_000), "1,000M")
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(1_500_000), "1.5M")
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(250_000), "250k")
        XCTAssertEqual(HistoryCopy.tokenAxisLabel(800), "800")
    }

    func testABarsFigureIsWholeDollarsFromTen() {
        XCTAssertEqual(HistoryCopy.costBarLabel(518.2), "$518")
        XCTAssertEqual(HistoryCopy.costBarLabel(1_352.28), "$1,352")
        XCTAssertEqual(HistoryCopy.costBarLabel(9.99), "$9.99")
        XCTAssertEqual(HistoryCopy.costBarLabel(4.734), "$4.73")
    }

    func testATokenBarsFigureIsTheTokenFormat() {
        XCTAssertEqual(HistoryCopy.tokenBarLabel(505_500_000), "505.5M")
        XCTAssertEqual(HistoryCopy.tokenBarLabel(4_800_000), "4.8M")
    }

    func testTheAxisNamesADayTheWayTheChatListDoes() {
        // 2026-08-30 00:00 UTC.
        let day = Date(timeIntervalSince1970: 1_788_048_000)
        XCTAssertEqual(HistoryCopy.axisDay(day, calendar: SessionFixture.calendar, locale: SessionFixture.locale), "30 Aug")
    }

    func testAnEmptyChartSaysSoAndAsksForARun() {
        XCTAssertEqual(HistoryCopy.emptyChartTitle, "No CLI usage in this range")
        XCTAssertEqual(HistoryCopy.emptyChartHint(command: "codex"), "Run a `codex` session to start collecting data")
    }
}

/// The quota chart's figures and its empty state.
final class HistoryCopyQuotaTests: XCTestCase {
    /// Sunday 6 September 2026, 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_788_696_000)

    func testPercentagesAreWhole() {
        XCTAssertEqual(HistoryCopy.percent(28.6), "29%")
        XCTAssertEqual(HistoryCopy.percent(0), "0%")
        XCTAssertEqual(HistoryCopy.percent(100), "100%")
    }

    func testTheTimeAxisNamesHoursDaysOrMonths() {
        XCTAssertEqual(
            HistoryCopy.quotaAxisLabel(noon, range: .oneDay, calendar: SessionFixture.calendar, locale: SessionFixture.locale),
            "12:00"
        )
        XCTAssertEqual(
            HistoryCopy.quotaAxisLabel(noon, range: .sevenDays, calendar: SessionFixture.calendar, locale: SessionFixture.locale),
            "6 Sep"
        )
        XCTAssertEqual(
            HistoryCopy.quotaAxisLabel(noon, range: .oneYear, calendar: SessionFixture.calendar, locale: Locale(identifier: "en_US")),
            "Sep"
        )
    }

    func testAnEmptyQuotaChartSaysWhoseAndWhen() {
        XCTAssertEqual(HistoryCopy.noQuotaTitle(provider: "Antigravity"), "No quota recorded yet for Antigravity")
        XCTAssertEqual(
            HistoryCopy.noQuotaHint,
            "Windows are recorded on every successful poll — this fills in as the app runs."
        )
    }
}
