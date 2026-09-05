import XCTest
@testable import Omelette

/// Independent verification of the pure `AgentRowText` rules that back the row's
/// chevron and its "where does the answer go" wording
/// (`docs/superpowers/specs/2026-09-06-clear-requests-and-codex-approvals-design.md`
/// § "Rows"), exercised directly rather than by re-reading `AgentRowTextTests.swift`.
/// `OMAgentRow` itself is a SwiftUI view and is not instantiated here; its behaviour
/// is checked by reading `OMAgentRow.swift` and reported separately.
final class AgentRowTextVerificationTests: XCTestCase {
    func testDetailIsExpandableIsFalseForNilEmptyAndWhitespaceOnly() {
        XCTAssertFalse(AgentRowText.detailIsExpandable(nil))
        XCTAssertFalse(AgentRowText.detailIsExpandable(""))
        XCTAssertFalse(AgentRowText.detailIsExpandable("\n\t  "))
    }

    func testDetailIsExpandableIsTrueForAnyRealText() {
        XCTAssertTrue(AgentRowText.detailIsExpandable("x"))
        XCTAssertTrue(AgentRowText.detailIsExpandable("/Users/me/Desktop/Usage tracker/UsageTracker/UI/PopoverView.swift"))
        XCTAssertTrue(AgentRowText.detailIsExpandable("Which provider?\n• Claude\n• Codex"))
    }

    func testJumpHelpIsTheAnswerSentenceForBothAttentionCases() {
        var question = Fixture.agentSession(projectName: "Usage tracker", state: .needsYou, activity: "Question: Ship today?")
        question.attention = .question(count: 1, multiSelect: false)
        XCTAssertEqual(AgentRowText.jumpHelp(for: question), "Click to go to the terminal and answer")

        var plan = Fixture.agentSession(projectName: "Usage tracker", state: .needsYou, activity: "Plan ready for review: X")
        plan.attention = .plan
        XCTAssertEqual(AgentRowText.jumpHelp(for: plan), "Click to go to the terminal and answer")
    }

    func testJumpHelpIsTheProjectJumpForANormalPermissionHold() {
        // A held permission is needsYou too, but it has no `attention` — the row can
        // answer it directly with Allow/Deny, so clicking still jumps to the project.
        let held = Fixture.agentSession(projectName: "Usage tracker", state: .needsYou, activity: "Clear the derived data")
        XCTAssertEqual(AgentRowText.jumpHelp(for: held), "Jump to Usage tracker")
    }

    func testPermissionButtonsFollowThePendingIDForBothAgents() {
        // Since the Codex hooks landed, a held request shows Allow / Deny whichever
        // agent it came from; an attention row (no pending id) never does.
        XCTAssertTrue(AgentRowText.permissionButtonsVisible(pendingPermissionID: "req-1", source: .codex))
        XCTAssertTrue(AgentRowText.permissionButtonsVisible(pendingPermissionID: "req-1", source: .claude))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: nil, source: .codex))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: nil, source: .claude))
    }
}
