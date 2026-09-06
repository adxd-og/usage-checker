import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `AgentNotificationRules.attentionBody` / `.attentionLead` (item 6 of the batch
/// brief): a plan whose detail carries only its own title line (nothing left once
/// the redundant first line is dropped) and a question whose detail carries no
/// bullet options at all.
final class AgentNotificationRulesVerification2Tests: XCTestCase {
    func testAPlanWhoseDetailIsOnlyItsTitleLineLeavesNoExtraLines() {
        // `attentionBody` drops the headline's "Plan ready for review: " prefix and
        // then, from the detail, drops the first non-empty line (the title, said
        // again) before taking up to two more. When the detail *is* just that one
        // line, there must be nothing left to append — not an empty trailing line,
        // not the title repeated a third time.
        let body = AgentNotificationRules.attentionBody(
            headline: "Plan ready for review: Rework the ring",
            detail: "# Rework the ring",
            attention: .plan
        )
        XCTAssertEqual(body, "Rework the ring", "the title from the headline, and nothing appended under it")
    }

    func testAQuestionWithNoBulletOptionsIsJustTheQuestionItself() {
        // A question payload whose detail has no "• " lines at all (zero options) —
        // `extra` filters for the bullet prefix, so it must come back empty rather
        // than accidentally picking up the question text itself as an "option".
        let body = AgentNotificationRules.attentionBody(
            headline: "Question: Tabs or spaces?",
            detail: "Tabs or spaces?",
            attention: .question(count: 1, multiSelect: false)
        )
        XCTAssertEqual(body, "Tabs or spaces?", "no bullets in the detail, so no options are appended")
    }

    func testAMultiQuestionHeadlineWithNoBulletOptionsIsJustTheLead() {
        let body = AgentNotificationRules.attentionBody(
            headline: "3 questions: Tabs or spaces?",
            detail: "Tabs or spaces?",
            attention: .question(count: 3, multiSelect: false)
        )
        XCTAssertEqual(body, "Tabs or spaces?")
    }

    func testAttentionLeadOnAPlanHeadlineThatIsOnlyTheBareSentenceIsEmpty() {
        XCTAssertEqual(AgentNotificationRules.attentionLead(headline: "Plan ready for review", attention: .plan), "")
    }

    func testAttentionLeadOnAQuestionHeadlineThatIsOnlyTheBareSentenceIsEmpty() {
        XCTAssertEqual(
            AgentNotificationRules.attentionLead(headline: "3 questions for you", attention: .question(count: 3, multiSelect: false)),
            ""
        )
    }
}
