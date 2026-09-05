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

        let waiting = AgentsSettingsText.codexTrustLine(awaiting)
        XCTAssertFalse(waiting.isTrusted)
        XCTAssertTrue(waiting.text.hasPrefix("Run /hooks in Codex once"), waiting.text)
        XCTAssertTrue(waiting.text.contains("PermissionRequest, PreToolUse"), waiting.text)
        XCTAssertTrue(waiting.text.hasSuffix("until then Codex ignores them"), waiting.text)
    }

    func testTheTrustLineNamesNoEventsWhenThereAreNone() {
        let line = AgentsSettingsText.codexTrustLine(.awaitingTrust(untrusted: []))
        XCTAssertFalse(line.isTrusted)
        XCTAssertFalse(line.text.contains("()"), line.text)
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
