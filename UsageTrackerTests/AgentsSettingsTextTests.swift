import SwiftUI
import XCTest
@testable import Omelette

/// The Agents tab reads the real ~/.claude and ~/.codex, which a test cannot; these
/// are the parts of it that are worth pinning — the words and the colours.
final class AgentsSettingsTextTests: XCTestCase {
    private let awaiting = AgentHooksInstaller.CodexTrustStatus.awaitingTrust(
        untrusted: ["PermissionRequest", "PreToolUse"]
    )

    func testEveryStatusHasALabelAndATint() {
        XCTAssertEqual(AgentsSettingsText.hookStatusLabel(.installed), "Installed")
        XCTAssertEqual(AgentsSettingsText.hookStatusLabel(.outdated), "Installed — older than this build")
        XCTAssertEqual(AgentsSettingsText.hookStatusLabel(.notInstalled), "Not installed")
        XCTAssertEqual(AgentsSettingsText.hookStatusLabel(.conflict("x")), "Can't write — something else owns this")

        XCTAssertEqual(AgentsSettingsText.hookStatusTint(.installed), .green)
        XCTAssertEqual(AgentsSettingsText.hookStatusTint(.outdated), .orange)
        XCTAssertEqual(AgentsSettingsText.hookStatusTint(.notInstalled), .secondary)
        XCTAssertEqual(AgentsSettingsText.hookStatusTint(.conflict("x")), .red)
    }

    func testTheTrustLineSaysWhatIsStillMissing() {
        let trusted = AgentsSettingsText.codexTrustLine(.trusted)
        XCTAssertEqual(trusted.text, "Trusted in Codex")
        XCTAssertTrue(trusted.isTrusted)

        // The events are wire names — "PermissionRequest, PreToolUse" is a list
        // nobody can act on. How many are still waiting is the part that changes as
        // the user works through /hooks.
        let waiting = AgentsSettingsText.codexTrustLine(awaiting)
        XCTAssertFalse(waiting.isTrusted)
        XCTAssertEqual(
            waiting.text,
            "Run /hooks in Codex once and trust the Omelette hooks (2 awaiting) — until then Codex ignores them"
        )
        XCTAssertFalse(waiting.text.contains("PermissionRequest"), waiting.text)
    }

    func testTheTrustLineCountsWhatIsLeft() {
        let one = AgentsSettingsText.codexTrustLine(.awaitingTrust(untrusted: ["Stop"]))
        XCTAssertTrue(one.text.contains("(1 awaiting)"), one.text)
        XCTAssertFalse(one.text.contains("Stop"), one.text)
    }

    func testThePermissionsCaptionAppearsOnlyWhileNothingCanHold() {
        XCTAssertNil(AgentsSettingsText.permissionsInactiveCaption(
            claude: .installed, codexHooks: .notInstalled, codexTrust: awaiting
        ))
        XCTAssertNil(AgentsSettingsText.permissionsInactiveCaption(
            claude: .notInstalled, codexHooks: .installed, codexTrust: .trusted
        ))
        XCTAssertEqual(
            AgentsSettingsText.permissionsInactiveCaption(
                claude: .notInstalled, codexHooks: .installed, codexTrust: awaiting
            ),
            "Inactive until the Claude Code or Codex hooks above are installed (and, for Codex, trusted)."
        )
        XCTAssertNotNil(AgentsSettingsText.permissionsInactiveCaption(
            claude: .outdated, codexHooks: .notInstalled, codexTrust: .trusted
        ))
    }
}
