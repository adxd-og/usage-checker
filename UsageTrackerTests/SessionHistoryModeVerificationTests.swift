import XCTest
@testable import Omelette

/// Independent verification of `DashboardState.hasSessionLog`, the gate on History's
/// chat list, against docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4:
/// exactly Claude, Codex and (spec 2026-11-10 Mistral provider § Local usage (P2)) Mistral, case-sensitively.
final class SessionHistoryModeVerificationTests: XCTestCase {
    func testHasSessionLogIsTrueForExactlyClaudeCodexAndMistralAndNothingElse() {
        let trueCases = ["claude", "codex", "mistral"]
        let falseCases = ["grok", "gemini", "antigravity", "", "Claude", "CODEX", "claude "]
        for id in trueCases {
            XCTAssertTrue(DashboardState.hasSessionLog(for: id), id)
        }
        for id in falseCases {
            XCTAssertFalse(DashboardState.hasSessionLog(for: id), id)
        }
    }
}
