import XCTest
@testable import Omelette

/// Independent verification of the pure rules behind History's third mode
/// (`DashboardState.hasSessionLog`, `SessionHistoryView.modes` / `effectiveMode` /
/// `sessionsSubtitle`) against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4 and the plan's
/// decisions 1, 2 and 12. Written from the spec and the diff, not from
/// `SessionHistoryModeTests` — this file walks every `TimeRange` case (the existing
/// suite tries three of five) to confirm the "today, not the last 5 hours" clause is
/// unique to the five-hour range, checks `hasSessionLog`'s case sensitivity, and checks
/// that a remembered Cost/Tokens choice is untouched by the session-log gate that only
/// ever redirects `.sessions`.
final class SessionHistoryModeVerificationTests: XCTestCase {
    // MARK: - Only the five-hour range says "not the last 5 hours"

    func testOnlyTheFiveHourRangeAppendsTheTodayClarification() {
        for range in TimeRange.allCases {
            let subtitle = SessionHistoryView.sessionsSubtitle(source: "Claude Code's session logs", range: range, isPayAsYouGo: false)
            if range == .fiveHours {
                XCTAssertTrue(subtitle.hasSuffix("· today, not the last 5 hours"), "\(range): \(subtitle)")
            } else {
                XCTAssertFalse(subtitle.contains("not the last 5 hours"), "\(range): \(subtitle)")
            }
        }
    }

    // MARK: - hasSessionLog is exactly two providers, case-sensitively

    func testHasSessionLogIsTrueForExactlyClaudeAndCodexAndNothingElse() {
        let trueCases = ["claude", "codex"]
        let falseCases = ["grok", "gemini", "antigravity", "", "Claude", "CODEX", "claude "]
        for id in trueCases {
            XCTAssertTrue(DashboardState.hasSessionLog(for: id), id)
        }
        for id in falseCases {
            XCTAssertFalse(DashboardState.hasSessionLog(for: id), id)
        }
    }

    // MARK: - The gate only ever touches a stored .sessions choice

    func testEffectiveModeLeavesCostAndTokensAloneRegardlessOfTheSessionLogGate() {
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .cost, hasSessionLog: false), .cost)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .cost, hasSessionLog: true), .cost)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .tokens, hasSessionLog: false), .tokens)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .tokens, hasSessionLog: true), .tokens)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .sessions, hasSessionLog: true), .sessions)
        XCTAssertEqual(SessionHistoryView.effectiveMode(stored: .sessions, hasSessionLog: false), .cost)
    }

    func testModesNeverOffersSessionsWithoutALogAndAlwaysPutsItLast() {
        XCTAssertEqual(SessionHistoryView.modes(hasSessionLog: false), [.cost, .tokens])
        XCTAssertEqual(SessionHistoryView.modes(hasSessionLog: true), [.cost, .tokens, .sessions])
    }
}
