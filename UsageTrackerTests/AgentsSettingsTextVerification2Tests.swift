import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `AgentsSettingsText.codexTrustLine` (item 6 of the batch brief): the exact
/// sentence at n = 1 and n = 7, pinned in full rather than as a substring — the
/// executor's own tests check `.contains("(1 awaiting)")` but never the whole
/// string, and never a count above 2.
final class AgentsSettingsTextVerification2Tests: XCTestCase {
    func testTheTrustLineAtExactlyOneAwaitingIsTheFullSingularSentence() {
        let line = AgentsSettingsText.codexTrustLine(.awaitingTrust(untrusted: ["Stop"]))
        XCTAssertFalse(line.isTrusted)
        XCTAssertEqual(
            line.text,
            "Run /hooks in Codex once and trust the Omelette hooks (1 awaiting) — until then Codex ignores them"
        )
    }

    func testTheTrustLineAtSevenAwaitingIsTheFullSentenceWithAllEventsCounted() {
        // Seven is every event Codex fires (`AgentHooksInstaller.codexHookEvents.count`),
        // i.e. nothing at all is trusted yet.
        let line = AgentsSettingsText.codexTrustLine(
            .awaitingTrust(untrusted: AgentHooksInstaller.codexHookEvents)
        )
        XCTAssertEqual(AgentHooksInstaller.codexHookEvents.count, 7, "the count this test pins is exactly 7")
        XCTAssertFalse(line.isTrusted)
        XCTAssertEqual(
            line.text,
            "Run /hooks in Codex once and trust the Omelette hooks (7 awaiting) — until then Codex ignores them"
        )
        for event in AgentHooksInstaller.codexHookEvents {
            XCTAssertFalse(line.text.contains(event), "wire event names must not leak into the sentence: \(event)")
        }
    }
}
