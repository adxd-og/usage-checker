import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of `PermissionBroker.featureIsUsable`'s truth table,
/// `AgentRowText.permissionButtonsVisible` for Codex, and the Settings text rules —
/// written from the spec's Package B section, not adapted from the executor's own
/// `PermissionBrokerTests` / `AgentRowTextTests` / `AgentsSettingsTextTests`.
final class PermissionBrokerAndSettingsVerificationTests: XCTestCase {
    private func usable(
        _ setting: Bool, _ claude: HookInstallStatus, _ codex: HookInstallStatus,
        _ trust: AgentHooksInstaller.CodexTrustStatus
    ) -> Bool {
        PermissionBroker.featureIsUsable(
            settingEnabled: setting, claudeHooks: claude, codexHooks: codex, codexTrust: trust
        )
    }

    // MARK: - featureIsUsable: combinations not in the plan's own fixture

    func testClaudeOutdatedButCodexInstalledAndTrustedIsStillUsable() {
        // An installer bug that only checked "is Claude ever installed" (ignoring
        // .outdated meaning "wrong template") would wrongly gate the whole feature
        // off here, even though Codex alone is perfectly able to hold requests.
        XCTAssertTrue(usable(true, .outdated, .installed, .trusted))
    }

    func testCodexInstalledButAwaitingTrustWithNoUsableClaudeIsUnusable() {
        XCTAssertFalse(usable(true, .notInstalled, .installed, .awaitingTrust(untrusted: [])))
        XCTAssertFalse(usable(true, .conflict("x"), .installed, .awaitingTrust(untrusted: ["PermissionRequest"])))
    }

    func testSettingOffOverridesEvenTwoFullyUsableAgents() {
        XCTAssertFalse(usable(false, .installed, .installed, .trusted))
    }

    func testBothOutdatedIsUnusableRegardlessOfTrust() {
        XCTAssertFalse(usable(true, .outdated, .outdated, .trusted))
    }

    func testClaudeConflictWithCodexTrustedIsStillUsableBecauseCodexAloneIsEnough() {
        XCTAssertTrue(usable(true, .conflict("settings.json isn't valid JSON"), .installed, .trusted))
    }

    // MARK: - permissionButtonsVisible: whitespace-only id counts as blank

    func testWhitespaceOnlyPendingIDNeverShowsButtonsForEitherSource() {
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "\n\t ", source: .codex))
        XCTAssertFalse(AgentRowText.permissionButtonsVisible(pendingPermissionID: "\n\t ", source: .claude))
    }

    func testARealIDShowsButtonsForBothSourcesIdentically() {
        XCTAssertEqual(
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "abc123", source: .codex),
            AgentRowText.permissionButtonsVisible(pendingPermissionID: "abc123", source: .claude),
            "the spec makes the id the only thing that decides this, for either source"
        )
    }

    // MARK: - AgentsSettingsText: single untrusted event (no comma, no trailing junk)

    func testTrustLineWithExactlyOneUntrustedEventHasNoStrayComma() {
        let line = AgentsSettingsText.codexTrustLine(.awaitingTrust(untrusted: ["PermissionRequest"]))
        XCTAssertFalse(line.isTrusted)
        XCTAssertTrue(line.text.contains("(PermissionRequest)"), line.text)
        XCTAssertFalse(line.text.contains(", )"), line.text)
        XCTAssertFalse(line.text.contains("(, "), line.text)
    }

    // MARK: - The permissions caption agrees with the broker for every corner the plan's own test omits

    func testCaptionIsNilExactlyWhenBrokerWouldHoldSomethingRegardlessOfWhichAgent() {
        let combinations: [(HookInstallStatus, HookInstallStatus, AgentHooksInstaller.CodexTrustStatus)] = [
            (.installed, .notInstalled, .awaitingTrust(untrusted: [])),
            (.notInstalled, .installed, .trusted),
            (.outdated, .installed, .trusted),
            (.notInstalled, .notInstalled, .trusted),
            (.outdated, .outdated, .trusted),
            (.notInstalled, .installed, .awaitingTrust(untrusted: ["Stop"])),
        ]
        for (claude, codex, trust) in combinations {
            let caption = AgentsSettingsText.permissionsInactiveCaption(claude: claude, codexHooks: codex, codexTrust: trust)
            let broker = PermissionBroker.featureIsUsable(
                settingEnabled: true, claudeHooks: claude, codexHooks: codex, codexTrust: trust
            )
            XCTAssertEqual(caption == nil, broker, "\(claude) \(codex) \(trust)")
        }
    }

    // MARK: - Codex hook events list: PermissionRequest is first (the trust line lists it that way)

    func testCodexHookEventsListsPermissionRequestFirst() {
        XCTAssertEqual(AgentHooksInstaller.codexHookEvents.first, "PermissionRequest")
        XCTAssertFalse(AgentHooksInstaller.codexHookEvents.contains("Notification"), "Codex has no Notification event")
        XCTAssertFalse(AgentHooksInstaller.codexHookEvents.contains("SubagentStart"))
        XCTAssertFalse(AgentHooksInstaller.codexHookEvents.contains("SubagentStop"))
    }
}
