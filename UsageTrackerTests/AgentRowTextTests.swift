import XCTest
@testable import Omelette

final class AgentRowTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

    // MARK: subtitle

    func testSubtitlePrefersTheActivity() {
        let session = Fixture.agentSession(state: .needsYou, activity: "Bash: xcodegen generate")
        XCTAssertEqual(AgentRowText.subtitle(for: session), "Bash: xcodegen generate")
    }

    func testSubtitleFallsBackToTheStatePhrase() {
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .needsYou)), "Needs approval")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .working)), "Working")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .done)), "Done")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .idle)), "Idle")
    }

    func testBlankActivityCountsAsNoActivity() {
        let session = Fixture.agentSession(state: .working, activity: "   ")
        XCTAssertEqual(AgentRowText.subtitle(for: session), "Working")
    }

    func testApproximateSessionsAreMarked() {
        let scanned = Fixture.agentSession(state: .working, activity: "Edit: WalletView.swift", isApproximate: true)
        XCTAssertEqual(AgentRowText.subtitle(for: scanned), "≈ Edit: WalletView.swift")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .idle, isApproximate: true)), "≈ Idle")
    }

    /// Provider-tab rows have no group heading above them, so the state is spelled
    /// out in front of the activity (mockup: "Needs approval · Bash: xcodegen generate").
    func testProviderTabRowsPrefixTheStateToTheActivity() {
        let session = Fixture.agentSession(state: .needsYou, activity: "Bash: xcodegen generate")
        XCTAssertEqual(AgentRowText.subtitle(for: session, showsState: true), "Needs approval · Bash: xcodegen generate")
        XCTAssertEqual(AgentRowText.subtitle(for: Fixture.agentSession(state: .working), showsState: true), "Working")
        let scanned = Fixture.agentSession(state: .working, activity: "Edit: A.swift", isApproximate: true)
        XCTAssertEqual(AgentRowText.subtitle(for: scanned, showsState: true), "≈ Working · Edit: A.swift")
    }

    // MARK: elapsed

    func testElapsedForLiveStatesIsADuration() {
        XCTAssertEqual(AgentRowText.elapsed(since: at(0.5), now: now, state: .working), "now")
        XCTAssertEqual(AgentRowText.elapsed(since: at(1), now: now, state: .working), "1m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(14), now: now, state: .needsYou), "14m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(125), now: now, state: .working), "2h 05m")
        XCTAssertEqual(AgentRowText.elapsed(since: at(60 * 26), now: now, state: .working), "1d")
    }

    func testElapsedForFinishedStatesReadsAsThePast() {
        XCTAssertEqual(AgentRowText.elapsed(since: at(5), now: now, state: .done), "5m ago")
        XCTAssertEqual(AgentRowText.elapsed(since: at(90), now: now, state: .idle), "1h 30m ago")
        XCTAssertEqual(AgentRowText.elapsed(since: at(0.2), now: now, state: .done), "just now")
    }

    /// Hook timestamps come from another process; a clock skew must not print "-3m".
    func testElapsedNeverGoesNegative() {
        XCTAssertEqual(AgentRowText.elapsed(since: now.addingTimeInterval(120), now: now, state: .working), "now")
    }

    // MARK: accessibility

    func testAccessibilityLabelCombinesEverything() {
        let session = Fixture.agentSession(
            projectName: "Usage tracker", state: .needsYou,
            activity: "Bash: xcodegen generate", stateSince: at(1)
        )
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "Usage tracker, Claude Code, Needs approval, Bash: xcodegen generate, for 1 minute"
        )
    }

    func testAccessibilityLabelWithoutActivity() {
        let session = Fixture.agentSession(source: .codex, projectName: "orion-gemini", state: .done, stateSince: at(5))
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "orion-gemini, Codex, Done, 5 minutes ago"
        )
    }

    func testAccessibilityLabelSaysApproximateInsteadOfPrintingTheSymbol() {
        let session = Fixture.agentSession(
            projectName: "Jaravis", state: .working,
            activity: "editing WalletView.swift", stateSince: at(14), isApproximate: true
        )
        XCTAssertEqual(
            AgentRowText.accessibilityLabel(for: session, now: now),
            "Jaravis, Claude Code, Working, approximately editing WalletView.swift, for 14 minutes"
        )
    }

    // MARK: permission buttons

    func testTheButtonsAppearOnlyForAHeldClaudeRequest() {
        XCTAssertTrue(
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "0f1e2d3c", source: .claude)
        )
    }

    func testARowWithNoHeldRequestOffersNoButtons() {
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: nil, source: .claude))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "", source: .claude))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "   ", source: .claude))
    }

    func testCodexNeverOffersButtons() {
        // Codex has no approval hook, so nothing on its side is waiting for an
        // answer. Buttons that answer nothing are worse than no buttons, whatever
        // the store happens to hold.
        XCTAssertFalse(
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "0f1e2d3c", source: .codex)
        )
    }
}
