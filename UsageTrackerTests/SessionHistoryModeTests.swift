import XCTest
@testable import Omelette

/// History's third mode: which providers are offered it, what happens to a remembered
/// choice under a provider that has no chats, and what the subtitle says — including
/// the one range that does not mean what it says.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4.
final class SessionHistoryModeTests: XCTestCase {
    // MARK: - Which providers have chats at all

    func testOnlyTheTwoProvidersWhoseLogsIdentifyAChatOfferTheMode() {
        // Grok writes a per-turn cost log — DashboardState.costSource says so — but
        // nothing in it names a chat, so its sessions() answers [] forever.
        XCTAssertTrue(DashboardState.hasSessionLog(for: "claude"))
        XCTAssertTrue(DashboardState.hasSessionLog(for: "codex"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "grok"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "gemini"))
        XCTAssertFalse(DashboardState.hasSessionLog(for: "antigravity"))
    }

    func testTheModeIsOfferedLastAndOnlyWhereItWorks() {
        XCTAssertEqual(SessionHistoryView.modes(hasSessionLog: true), [.cost, .tokens, .sessions])
        XCTAssertEqual(SessionHistoryView.modes(hasSessionLog: false), [.cost, .tokens])
    }

    // MARK: - A remembered choice that no longer applies

    func testASessionsChoiceFallsBackToCostUnderAProviderWithNoChats() {
        // historyChartMode is one persisted value across every provider. Landing on
        // Grok's tab must show a chart, not an empty list.
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .sessions, hasSessionLog: false), .cost)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .sessions, hasSessionLog: true), .sessions)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .tokens, hasSessionLog: false), .tokens)
    }

    // MARK: - The subtitle

    func testTheSessionsSubtitleNamesTheLogAndTheKindOfDollars() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude",
                longName: "Claude Code's session logs",
                mode: .sessions, isPayAsYouGo: false, range: .sevenDays
            ),
            "Chats from Claude Code's session logs, tokens and API-equivalent cost"
        )
    }

    func testPayAsYouGoDollarsAreNotCalledApiEquivalentHereEither() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude",
                longName: "Claude Code's session logs",
                mode: .sessions, isPayAsYouGo: true, range: .sevenDays
            ),
            "Chats from Claude Code's session logs, tokens and cost"
        )
    }

    func testAFiveHourRangeSaysItIsReallyShowingToday() {
        // The aggregators widen anything shorter than a day to the local day it falls
        // in (§ 1). The subtitle is where that is said out loud.
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Codex",
                longName: "the Codex CLI's session logs",
                mode: .sessions, isPayAsYouGo: false, range: .fiveHours
            ),
            "Chats from the Codex CLI's session logs, tokens and API-equivalent cost · today, not the last 5 hours"
        )
    }

    func testAProviderWithNoNamedSourceStillReadsAsASentence() {
        XCTAssertEqual(
            SessionHistoryView.sessionsSubtitle(source: nil, range: .thirtyDays, isPayAsYouGo: false),
            "Chats, tokens and API-equivalent cost"
        )
    }

    func testTheOtherTwoModesAreUnchanged() {
        // The new `range:` parameter is defaulted and must change nothing for them.
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude", longName: "Claude Code logs",
                mode: .tokens, isPayAsYouGo: false
            ),
            "Daily tokens by type from Claude Code logs"
        )
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: true, providerName: "Antigravity", longName: nil,
                mode: .sessions, isPayAsYouGo: false, range: .fiveHours
            ),
            "How full Antigravity's usage windows ran",
            "a provider with no cost log never reaches the sessions branch"
        )
    }
}
