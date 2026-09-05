import XCTest
@testable import Omelette

/// Independent verification of the banner copy rules against
/// `docs/superpowers/specs/2026-09-06-clear-requests-and-codex-approvals-design.md`
/// § "Notifications" (`AgentNotificationRules`, `UsageNotifier.needsYouBanner`),
/// exercised directly rather than by re-reading `AgentNotificationRulesTests.swift` /
/// `UsageNotifierRulesTests.swift`. Covers the MCP subtitle case, the exact 200-char
/// cap boundary, the "up to three option lines" / "two plan lines" caps, and the
/// choice `needsYouBanner(for:)` makes between the plain sentence and the
/// project-and-provider shape.
final class AgentAttentionBannerVerificationTests: XCTestCase {
    // MARK: - Permission banner

    func testPermissionSubtitleNamesAnMCPServerNotTheWireToolName() {
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "mcp__orion_gemini__gemini_research"),
            "Wants to use Orion gemini"
        )
    }

    func testPermissionSubtitleForAHeldQuestionOrPlanNamesTheAnswerNotTheTool() {
        // A permission hold can in principle carry an attention (belt-and-braces, see
        // `PermissionBroker.register`): Allow then means "go ahead and ask in the
        // terminal", which naming the raw tool name would not say.
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "AskUserQuestion", attention: .question(count: 1, multiSelect: false)),
            "Wants to ask you a question"
        )
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "AskUserQuestion", attention: .question(count: 3, multiSelect: true)),
            "Wants to ask you a question"
        )
        XCTAssertEqual(
            AgentNotificationRules.permissionSubtitle(toolName: "ExitPlanMode", attention: .plan),
            "Wants to show you a plan"
        )
    }

    func testPermissionBodyDropsADetailThatOnlyRepeatsTheHeadlineAfterTrimming() {
        // Trailing whitespace on the detail must not defeat the "same as headline"
        // check.
        XCTAssertEqual(
            AgentNotificationRules.permissionBody(headline: "swift test", detail: "swift test  \n"),
            "swift test"
        )
    }

    func testPermissionBodyCapIsExactlyTwoHundredWithAnEllipsis() {
        let body = AgentNotificationRules.permissionBody(
            headline: "Clear the derived data",
            detail: String(repeating: "y", count: 500)
        )
        XCTAssertEqual(body.count, 200)
        XCTAssertTrue(body.hasSuffix("…"))
    }

    // MARK: - Attention subtitle: 1 vs n questions, and a plan

    func testAttentionSubtitleForOneQuestionDoesNotSayOneQuestion() {
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.question(count: 1, multiSelect: true)), "Has a question for you")
    }

    func testAttentionSubtitleCountsPluralQuestions() {
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.question(count: 5, multiSelect: false)), "5 questions for you")
    }

    func testAttentionSubtitleForAPlanIsFixed() {
        XCTAssertEqual(AgentNotificationRules.attentionSubtitle(.plan), "Plan ready for review")
    }

    // MARK: - Attention body: up to three option lines, up to two plan lines

    func testAQuestionBodyCapsAtThreeOptionLinesEvenWithFive() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Question: Which model?",
            detail: "Which model?\n• Sonnet\n• Opus\n• Haiku\n• Fable\n• Grok",
            attention: .question(count: 1, multiSelect: false)
        )
        XCTAssertEqual(body, "Question: Which model?\n• Sonnet\n• Opus\n• Haiku")
    }

    func testAPlanBodyCapsAtTwoLinesUnderTheTitleEvenWithFive() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Plan ready for review: Rework the ring",
            detail: "# Rework the ring\n\nStep one.\nStep two.\nStep three.\nStep four.",
            attention: .plan
        )
        XCTAssertEqual(body, "Plan ready for review: Rework the ring\nStep one.\nStep two.")
    }

    func testAPlanBodyIgnoresBlankLinesWhenCountingTheTwo() {
        let body = AgentNotificationRules.attentionBody(
            headline: "Plan ready for review: X",
            detail: "# X\n\n\nStep one.\n\nStep two.",
            attention: .plan
        )
        XCTAssertEqual(body, "Plan ready for review: X\nStep one.\nStep two.")
    }

    func testAnAttentionBodyWithNoDetailIsJustTheHeadline() {
        XCTAssertEqual(
            AgentNotificationRules.attentionBody(headline: "Has a question for you", detail: nil, attention: .question(count: 1, multiSelect: false)),
            "Has a question for you"
        )
    }

    // MARK: - needsYouBanner(for:) picks the right shape

    private func session(attention: AgentAttention?, activity: String?, detail: String?) -> AgentSession {
        var built = Fixture.agentSession(projectName: "Usage tracker", state: .needsYou, activity: activity)
        built.activityDetail = detail
        built.attention = attention
        return built
    }

    func testAPlainNeedsYouSessionGetsNoSubtitleAndTheOldSentenceTitle() {
        let banner = UsageNotifier.needsYouBanner(for: session(attention: nil, activity: "Regenerate the project", detail: "xcodegen generate"))
        XCTAssertEqual(banner.title, "Usage tracker needs your approval")
        XCTAssertNil(banner.subtitle)
        XCTAssertEqual(banner.body, "Regenerate the project", "the plain banner body is only the activity, not the detail")
    }

    func testAQuestionSessionGetsTheProjectProviderTitleAndOptions() {
        let banner = UsageNotifier.needsYouBanner(for: session(
            attention: .question(count: 2, multiSelect: false),
            activity: "2 questions: Ship today?",
            detail: "Ship today?\n• Yes\n• No\n\nWhich channel?\n• Stable\n• Beta"
        ))
        XCTAssertEqual(banner.title, "Usage tracker · Claude Code")
        XCTAssertEqual(banner.subtitle, "2 questions for you")
        XCTAssertEqual(banner.body, "2 questions: Ship today?\n• Yes\n• No\n• Stable")
    }

    func testACodexSessionUsesTheCodexProviderNameInTheAttentionTitle() {
        var built = Fixture.agentSession(sessionID: "s2", source: .codex, projectName: "Orion Gate", state: .needsYou, activity: "Plan ready for review: X")
        built.attention = .plan
        let banner = UsageNotifier.needsYouBanner(for: built)
        XCTAssertEqual(banner.title, "Orion Gate · Codex")
    }
}
