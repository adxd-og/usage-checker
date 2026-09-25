import XCTest
@testable import Omelette

/// Independent verification of `DashboardState.hasSessionLog`, the gate on History's
/// chat list, against docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4:
/// exactly two providers, case-sensitively.
final class SessionHistoryModeVerificationTests: XCTestCase {
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
}
