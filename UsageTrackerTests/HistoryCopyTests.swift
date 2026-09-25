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
