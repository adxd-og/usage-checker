import XCTest
@testable import Omelette

/// Built here rather than in `Fixture` on purpose: packages 2 and 4 also land test
/// code this week, and a shared `Fixture.agentSession` would be three sessions
/// editing one file. Nothing outside this file needs it.
///
/// `AgentSession` computes its own `id` from source + sessionID
/// (`AgentSession.makeID`), so the builder takes the composite id the tests want to
/// talk about and splits it back into the two fields the initializer accepts.
private func agentSession(
    id: String = "claude:abc-123",
    project: String = "Usage tracker",
    state: AgentState = .needsYou,
    activity: String? = "Bash: xcodegen generate",
    turns: Int = 1
) -> AgentSession {
    let source: AgentSource = id.hasPrefix("codex") ? .codex : .claude
    let sessionID = String(id.drop(while: { $0 != ":" }).dropFirst())
    return AgentSession(
        sessionID: sessionID.isEmpty ? "abc-123" : sessionID,
        source: source,
        projectName: project,
        cwd: "/Users/me/\(project)",
        state: state,
        activity: activity,
        stateSince: Date(),
        lastEventAt: Date(),
        startedAt: Date(),
        host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
        isApproximate: false,
        turns: turns,
        needsYouCount: 1
    )
}

/// Which agent events may page the user. The notification centre is deliberately
/// out of reach here, exactly as in `UsageNotifierRulesTests`.
final class AgentNotificationGatingTests: XCTestCase {
    func testEveryNeedsYouToggleCombination() {
        // Both toggles against both quiet-hours states. `agentsNeedsYouBypassQuietHours`
        // is the only reason any notification in this app survives quiet hours.
        // The last column is phase 4: a session with a permission request in flight is
        // already being asked about by a banner that has Allow and Deny on it.
        let cases: [(notify: Bool, bypass: Bool, quiet: Bool, pending: Bool, expected: Bool)] = [
            (true,  true,  false, false, true),
            (true,  true,  true,  false, true),
            (true,  false, false, false, true),
            (true,  false, true,  false, false),
            (false, true,  false, false, false),
            (false, true,  true,  false, false),
            (false, false, false, false, false),
            (false, false, true,  false, false),
            // A pending request outranks every "yes" above it.
            (true,  true,  false, true,  false),
            (true,  true,  true,  true,  false),
        ]
        for c in cases {
            XCTAssertEqual(
                AgentNotificationRules.shouldNotifyNeedsYou(
                    notifyEnabled: c.notify,
                    bypassQuietHours: c.bypass,
                    isQuietHours: c.quiet,
                    permissionPending: c.pending
                ),
                c.expected,
                "notify=\(c.notify) bypass=\(c.bypass) quiet=\(c.quiet) pending=\(c.pending)"
            )
        }
    }

    func testDoneNeverSurvivesQuietHours() {
        // "Finished" is an FYI. Nothing about it is worth waking someone for, so it
        // has no bypass at all.
        XCTAssertTrue(AgentNotificationRules.shouldNotifyDone(notifyEnabled: true, isQuietHours: false))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: true, isQuietHours: true))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: false, isQuietHours: false))
        XCTAssertFalse(AgentNotificationRules.shouldNotifyDone(notifyEnabled: false, isQuietHours: true))
    }
}

/// The identifier is what stops a session's second approval prompt from stacking a
/// second banner, and what lets the app withdraw the banner afterwards.
final class AgentNotificationIdentifierTests: XCTestCase {
    func testTheIdentifierIsStablePerSessionSoARepeatReplacesTheBanner() {
        let first = agentSession(activity: "Bash: xcodegen generate")
        let second = agentSession(activity: "Edit: MenuBarLabel.swift")
        XCTAssertEqual(AgentNotificationRules.identifier(for: first), "agent-needsyou-claude:abc-123")
        XCTAssertEqual(
            AgentNotificationRules.identifier(for: first),
            AgentNotificationRules.identifier(for: second)
        )
    }

    func testTwoSessionsNeverShareAnIdentifier() {
        XCTAssertNotEqual(
            AgentNotificationRules.identifier(for: agentSession(id: "claude:abc")),
            AgentNotificationRules.identifier(for: agentSession(id: "codex:abc"))
        )
    }

    func testDoneAndNeedsYouDoNotCollide() {
        let session = agentSession()
        XCTAssertNotEqual(
            AgentNotificationRules.identifier(for: session),
            AgentNotificationRules.doneIdentifier(for: session)
        )
    }

    func testTheSessionIDSurvivesTheRoundTrip() {
        // A session id contains a colon ("claude:abc-123"), which is why this strips
        // a known prefix instead of splitting on a separator.
        let session = agentSession(id: "claude:abc-123")
        XCTAssertEqual(
            AgentNotificationRules.sessionID(
                fromIdentifier: AgentNotificationRules.identifier(for: session)
            ),
            "claude:abc-123"
        )
        XCTAssertEqual(
            AgentNotificationRules.sessionID(
                fromIdentifier: AgentNotificationRules.doneIdentifier(for: session)
            ),
            "claude:abc-123"
        )
    }

    func testSomebodyElsesNotificationIsNotOurs() {
        // Threshold and daily-summary notifications carry a UUID identifier; acting
        // on one must not try to jump anywhere.
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: UUID().uuidString))
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: "agent-needsyou-"))
    }
}

/// What the banner says.
final class AgentNotificationCopyTests: XCTestCase {
    func testTheTitleNamesTheProjectAndTheBodyTheTool() {
        let session = agentSession(project: "Usage tracker", activity: "Bash: xcodegen generate")
        XCTAssertEqual(AgentNotificationRules.title(for: session), "Usage tracker needs your approval")
        XCTAssertEqual(AgentNotificationRules.body(for: session), "Bash: xcodegen generate")
    }

    func testASessionWithoutAToolSummaryStillSaysSomething() {
        // A `Notification`-sourced needsYou carries no tool_input, so the body would
        // otherwise be empty and the banner would read as broken.
        XCTAssertEqual(
            AgentNotificationRules.body(for: agentSession(activity: nil)),
            "Waiting for your approval."
        )
    }

    func testALongCommandIsTruncatedWithAnEllipsis() {
        let long = "Bash: " + String(repeating: "x", count: 300)
        let body = AgentNotificationRules.body(for: agentSession(activity: long))
        XCTAssertEqual(body.count, AgentNotificationRules.maxBodyLength)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertTrue(body.hasPrefix("Bash: xxx"))
    }

    func testABodyThatFitsIsLeftAlone() {
        let body = AgentNotificationRules.body(for: agentSession(activity: "Edit: MenuBarLabel.swift"))
        XCTAssertEqual(body, "Edit: MenuBarLabel.swift")
    }

    func testTheDoneBodyCountsTurns() {
        XCTAssertEqual(
            AgentNotificationRules.doneTitle(for: agentSession(project: "Orion", state: .done)),
            "Orion finished"
        )
        XCTAssertEqual(
            AgentNotificationRules.doneBody(for: agentSession(state: .done, activity: nil, turns: 1)),
            "1 turn"
        )
        XCTAssertEqual(
            AgentNotificationRules.doneBody(
                for: agentSession(state: .done, activity: "Edit: MenuBarLabel.swift", turns: 7)
            ),
            "Edit: MenuBarLabel.swift · 7 turns"
        )
    }
}

/// The leaving edge. The store announces a session *entering* `needsYou`; nothing
/// announces it leaving, so the banner has to be withdrawn from a diff — a banner
/// that outlives the approval it asked for is worse than no banner.
final class AgentNotificationWithdrawalTests: XCTestCase {
    func testASessionThatStopsWaitingHasItsBannerWithdrawn() {
        XCTAssertEqual(
            AgentNotificationRules.resolvedSessionIDs(
                notified: ["claude:a", "claude:b"],
                sessions: [
                    agentSession(id: "claude:a", state: .needsYou),
                    agentSession(id: "claude:b", state: .working),
                ]
            ),
            ["claude:b"]
        )
    }

    func testASessionThatDisappearsEntirelyHasItsBannerWithdrawn() {
        XCTAssertEqual(
            AgentNotificationRules.resolvedSessionIDs(notified: ["claude:a"], sessions: []),
            ["claude:a"]
        )
    }

    func testASessionStillWaitingKeepsItsBanner() {
        XCTAssertTrue(
            AgentNotificationRules.resolvedSessionIDs(
                notified: ["claude:a"],
                sessions: [agentSession(id: "claude:a", state: .needsYou)]
            ).isEmpty
        )
    }

    func testASessionWeNeverNotifiedAboutIsNotWithdrawn() {
        XCTAssertTrue(
            AgentNotificationRules.resolvedSessionIDs(
                notified: [],
                sessions: [agentSession(id: "claude:a", state: .idle)]
            ).isEmpty
        )
    }
}

/// What the Allow / Deny banner says. Only the summary and the first line of the
/// full text leave the hook payload (design doc, security rule 6).
final class AgentPermissionNotificationCopyTests: XCTestCase {
    func testTheTitleIsTheProjectAndTheProvider() {
        XCTAssertEqual(
            AgentNotificationRules.permissionTitle(projectName: "Usage tracker", source: .claude),
            "Usage tracker · Claude Code"
        )
        XCTAssertEqual(
            AgentNotificationRules.permissionTitle(projectName: "Orion Gate", source: .codex),
            "Orion Gate · Codex"
        )
    }

    func testTheSubtitleNamesTheTool() {
        XCTAssertEqual(AgentNotificationRules.permissionSubtitle(toolName: "Bash"), "Wants to run Bash")
        XCTAssertEqual(AgentNotificationRules.permissionSubtitle(toolName: nil), "Wants to run a tool")
        XCTAssertEqual(AgentNotificationRules.permissionSubtitle(toolName: "   "), "Wants to run a tool")
    }

    func testAnMCPToolIsNamedByItsServer() {
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "mcp__notion__notion-fetch"),
            "Wants to use Notion"
        )
    }

    /// A PermissionRequest can arrive for AskUserQuestion itself, and then "Allow"
    /// means "go ahead and ask me in the terminal" — so the banner has to say a
    /// question is coming, not name the tool that carries it.
    func testARequestForAQuestionOrAPlanSaysSoInsteadOfNamingTheTool() {
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(
                toolName: "AskUserQuestion", attention: .question(count: 1, multiSelect: false)
            ),
            "Wants to ask you a question"
        )
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "ExitPlanMode", attention: .plan),
            "Wants to show you a plan"
        )
    }

    func testTheBodyIsTheHeadlineAndTheFirstLineOfTheFullText() {
        XCTAssertEqual(
            AgentNotificationRules.permissionBody(headline: "Clear the derived data", detail: "rm -rf build/DerivedData"),
            "Clear the derived data\nrm -rf build/DerivedData"
        )
    }

    func testADetailThatOnlyRepeatsTheHeadlineIsNotShownTwice() {
        XCTAssertEqual(
            AgentNotificationRules.permissionBody(headline: "swift test", detail: "swift test"),
            "swift test"
        )
        XCTAssertEqual(AgentNotificationRules.permissionBody(headline: "swift test", detail: nil), "swift test")
    }

    func testAMissingHeadlineFallsBackToTheWaitingSentence() {
        XCTAssertEqual(AgentNotificationRules.permissionBody(headline: nil, detail: "x"), "Waiting for your approval.")
        XCTAssertEqual(AgentNotificationRules.permissionBody(headline: " ", detail: nil), "Waiting for your approval.")
    }

    func testTheBodyIsCutAtTwoHundred() {
        let body = AgentNotificationRules.permissionBody(
            headline: "Clear the derived data",
            detail: String(repeating: "x", count: 400)
        )
        XCTAssertEqual(body.count, 200)
        XCTAssertEqual(AgentNotificationRules.maxPermissionBodyLength, 200)
        XCTAssertTrue(body.hasSuffix("…"))
        XCTAssertTrue(body.hasPrefix("Clear the derived data\nxxx"))
    }
}

/// What a question or a plan says on a banner with no buttons: the answer has to be
/// typed in the terminal, so the banner's job is to carry the text there.
final class AgentAttentionNotificationCopyTests: XCTestCase {
    private func session(_ attention: AgentAttention?) -> AgentSession {
        var built = Fixture.agentSession(projectName: "Usage tracker", state: .needsYou)
        built.attention = attention
        return built
    }

    func testTheTitleIsTheProjectAndTheProvider() {
        XCTAssertEqual(AgentNotificationRules.attentionTitle(for: session(.plan)), "Usage tracker · Claude Code")
    }

    func testTheSubtitleSaysWhatIsWaiting() {
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.question(count: 1, multiSelect: false)), "Has a question for you")
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.question(count: 3, multiSelect: true)), "3 questions for you")
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.plan), "Plan ready for review")
    }

    func testAQuestionBodyCarriesUpToThreeOptions() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Question: Which provider?",
            detail: "Which provider?\n• Claude\n• Codex\n• Grok\n• Gemini",
            attention: .question(count: 1, multiSelect: false)
        )
        XCTAssertEqual(body, "Question: Which provider?\n• Claude\n• Codex\n• Grok")
    }

    func testAPlanBodyCarriesTheTwoLinesUnderTheTitle() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Plan ready for review: Rework the ring",
            detail: "# Rework the ring\n\nStep one.\nStep two.\nStep three.",
            attention: .plan
        )
        XCTAssertEqual(body, "Plan ready for review: Rework the ring\nStep one.\nStep two.")
    }

    func testABodyWithNothingToAddIsJustTheHeadline() {
        XCTAssertEqual(
            AgentNotificationRules.attentionBody(headline: "Question for you", detail: nil, attention: .question(count: 1, multiSelect: false)),
            "Question for you"
        )
        XCTAssertEqual(
            AgentNotificationRules.attentionBody(headline: nil, detail: nil, attention: .plan),
            "Waiting for your answer in the terminal."
        )
    }

    func testTheBodyIsCutAtTwoHundred() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Plan ready for review: Rework the ring",
            detail: "# Rework the ring\n" + String(repeating: "x", count: 400),
            attention: .plan
        )
        XCTAssertEqual(body.count, 200)
        XCTAssertTrue(body.hasSuffix("…"))
    }
}

/// The identifier is what the app withdraws when the hold ends, and what carries the
/// request id back from a button press.
final class AgentPermissionNotificationIdentifierTests: XCTestCase {
    func testTheIdentifierIsTheRequestIDNotTheSession() {
        // Two requests from one session are two questions; filing them both under the
        // session would let the second replace the first and leave one unanswered.
        XCTAssertEqual(
            AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c"),
            "agent-permission-0f1e2d3c"
        )
        XCTAssertNotEqual(
            AgentNotificationRules.permissionIdentifier(requestID: "aaaa"),
            AgentNotificationRules.permissionIdentifier(requestID: "bbbb")
        )
    }

    func testTheRequestIDSurvivesTheRoundTrip() {
        let identifier = AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c4b5a")
        XCTAssertEqual(AgentNotificationRules.requestID(fromIdentifier: identifier), "0f1e2d3c4b5a")
    }

    func testSomebodyElsesNotificationCarriesNoRequestID() {
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: UUID().uuidString))
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: "agent-permission-"))
        XCTAssertNil(AgentNotificationRules.requestID(fromIdentifier: "agent-needsyou-claude:abc"))
    }

    func testAPermissionIdentifierIsNeverMistakenForASession() {
        // `handleAgentResponse` jumps to whatever session an identifier names; a request
        // id is not one, and answering must not be confused with jumping.
        let identifier = AgentNotificationRules.permissionIdentifier(requestID: "0f1e2d3c")
        XCTAssertNil(AgentNotificationRules.sessionID(fromIdentifier: identifier))
    }
}
