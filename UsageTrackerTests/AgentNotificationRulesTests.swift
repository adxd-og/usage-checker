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
        let cases: [(notify: Bool, bypass: Bool, quiet: Bool, expected: Bool)] = [
            (true,  true,  false, true),
            (true,  true,  true,  true),
            (true,  false, false, true),
            (true,  false, true,  false),
            (false, true,  false, false),
            (false, true,  true,  false),
            (false, false, false, false),
            (false, false, true,  false),
        ]
        for c in cases {
            XCTAssertEqual(
                AgentNotificationRules.shouldNotifyNeedsYou(
                    notifyEnabled: c.notify,
                    bypassQuietHours: c.bypass,
                    isQuietHours: c.quiet
                ),
                c.expected,
                "notify=\(c.notify) bypass=\(c.bypass) quiet=\(c.quiet)"
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
