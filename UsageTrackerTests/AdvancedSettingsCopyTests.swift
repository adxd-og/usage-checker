import XCTest
@testable import Omelette

/// Liquid-glass spec § Design → Settings, "Advanced: keychain, Admin API, weekly budget,
/// beta flag, diagnostics (moved from Agents), replay tour, reset"
/// (`Settings-Advanced.dc.html`). § Decisions: "[n] received · [n] dropped" is the live
/// counters.
final class AdvancedSettingsCopyTests: XCTestCase {
    func testASavedKeyShowsOnlyItsFirstFourteenCharacters() {
        XCTAssertEqual(AdvancedSettingsCopy.maskedKey("sk-ant-admin01-abcdefghijklmnop"), "Saved: sk-ant-admin01…")
        XCTAssertTrue(AdvancedSettingsCopy.hasSavedKey("sk-ant-admin01-abcdefghijklmnop"))
    }

    func testNoKeyReadsNotSetAndOffersNoDelete() {
        XCTAssertEqual(AdvancedSettingsCopy.maskedKey(nil), "Not set")
        XCTAssertEqual(AdvancedSettingsCopy.maskedKey(""), "Not set")
        XCTAssertFalse(AdvancedSettingsCopy.hasSavedKey(nil))
        XCTAssertFalse(AdvancedSettingsCopy.hasSavedKey(""))
    }

    func testTheKeychainResultIsAGreenOrAnAmberLine() {
        XCTAssertEqual(AdvancedSettingsCopy.keychainNote(.granted), SettingsCaption(text: "Access granted", token: .okText))
        XCTAssertEqual(
            AdvancedSettingsCopy.keychainNote(.failed("User canceled")),
            SettingsCaption(text: "Failed: User canceled", token: .warning)
        )
    }

    func testAgentMessagesCountBothWays() {
        XCTAssertEqual(AdvancedSettingsCopy.messages(received: 12, dropped: 0), "12 received · 0 dropped")
    }

    func testPermissionRequestsCountAllFour() {
        XCTAssertEqual(
            AdvancedSettingsCopy.permissionRequests(pending: 1, answered: 3, expired: 0, released: 2),
            "1 pending · 3 answered · 0 expired · 2 released to terminal"
        )
    }

    func testTheHelperIsNamedWithItsVersion() {
        XCTAssertEqual(AdvancedSettingsCopy.helper(version: 2), "omelette-hook v2")
    }

    func testTheSocketIsShownFromHome() {
        XCTAssertEqual(
            AdvancedSettingsCopy.socketCaption(
                path: "/Users/tester/Library/Application Support/UsageTracker/agent.sock", home: "/Users/tester"
            ),
            "Socket ~/Library/Application Support/UsageTracker/agent.sock"
        )
    }

    func testASocketThatFailedToStartIsARedLine() {
        XCTAssertEqual(AdvancedSettingsCopy.socketErrorNote("Address in use"), SettingsCaption(text: "Address in use", token: .critical))
        XCTAssertNil(AdvancedSettingsCopy.socketErrorNote(nil))
        XCTAssertNil(AdvancedSettingsCopy.socketErrorNote("  "))
    }

    func testTheLastEventIsAnAge() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(AdvancedSettingsCopy.lastEvent(nil, now: now), "—")
        XCTAssertEqual(AdvancedSettingsCopy.lastEvent(now.addingTimeInterval(-250), now: now), "4m ago")
    }

    func testTheRowsReadAsTheMockup() {
        XCTAssertEqual(AdvancedSettingsCopy.keychainHeader, "Claude keychain")
        XCTAssertEqual(AdvancedSettingsCopy.keychainTitle, "Request keychain access now")
        XCTAssertEqual(AdvancedSettingsCopy.keychainCaption, "Use it if Claude shows errors right after an install. Click Always Allow.")
        XCTAssertEqual(AdvancedSettingsCopy.keychainButton, "Request")
        XCTAssertEqual(AdvancedSettingsCopy.adminHeader, "Admin API, Enterprise only")
        XCTAssertEqual(AdvancedSettingsCopy.preferAdminTitle, "Prefer Admin API when available")
        XCTAssertEqual(AdvancedSettingsCopy.adminKeyTitle, "API key")
        XCTAssertEqual(AdvancedSettingsCopy.saveButton, "Save")
        XCTAssertEqual(AdvancedSettingsCopy.deleteButton, "Delete")
        XCTAssertEqual(AdvancedSettingsCopy.budgetHeader, "Budget and API")
        XCTAssertEqual(AdvancedSettingsCopy.budgetTitle, "Weekly budget, pay-as-you-go")
        XCTAssertEqual(AdvancedSettingsCopy.budgetCaption, "$0 shows dollars only, no percentage.")
        XCTAssertEqual(AdvancedSettingsCopy.betaTitle, "Anthropic beta flag")
        XCTAssertEqual(AdvancedSettingsCopy.diagnosticsHeader, "Diagnostics")
        XCTAssertEqual(AdvancedSettingsCopy.messagesTitle, "Agent messages")
        XCTAssertEqual(AdvancedSettingsCopy.resetHeader, "Reset")
        XCTAssertEqual(AdvancedSettingsCopy.replayTitle, "Replay welcome tour")
        XCTAssertEqual(AdvancedSettingsCopy.replayButton, "Replay")
        XCTAssertEqual(AdvancedSettingsCopy.resetTitle, "Reset all settings")
        XCTAssertEqual(AdvancedSettingsCopy.resetCaption, "Providers, thresholds, quiet hours, menu bar. Your Admin API key stays.")
        XCTAssertEqual(AdvancedSettingsCopy.resetButton, "Reset")
    }

    func testTheResetDialogKeepsIts2xWords() {
        XCTAssertEqual(AdvancedSettingsCopy.resetConfirmTitle, "Reset all settings?")
        XCTAssertEqual(AdvancedSettingsCopy.resetConfirmButton, "Reset everything")
        XCTAssertEqual(AdvancedSettingsCopy.cancelButton, "Cancel")
        XCTAssertTrue(AdvancedSettingsCopy.resetConfirmMessage.hasSuffix("Your saved Admin API key is not touched."))
    }

    /// The 2.x captions the mockup cut to one line survive as hover help.
    func testThe2xCaptionsSurviveAsHelp() {
        XCTAssertTrue(AdvancedSettingsCopy.keychainHelp.contains("skipping the hourly retry limit"))
        XCTAssertTrue(AdvancedSettingsCopy.adminHelp.contains("Team/Enterprise"))
        XCTAssertTrue(AdvancedSettingsCopy.budgetHelp.contains("measured against this budget"))
        XCTAssertTrue(AdvancedSettingsCopy.betaHelp.contains("Default: oauth-2025-04-20."))
        XCTAssertTrue(AdvancedSettingsCopy.messagesHelp.contains("the next prompt re-registers it"))
    }

    /// Keep-awake spec 2026-10-26 § UI: "Reset keep awake … ends the mode, clears the flag,
    /// unregisters the daemon, and resets the feature's settings".
    func testTheKeepAwakeResetRowReadsAsTheSpec() {
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeResetTitle, "Reset keep awake")
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeResetButton, "Reset")
        XCTAssertEqual(
            AdvancedSettingsCopy.keepAwakeResetHelp,
            "Ends keep awake, clears the sleep flag, removes the helper from Login Items and puts the battery floor and the last duration back. Asks for an administrator password only when the helper cannot clear the flag itself."
        )
    }

    /// § UI: "The row's caption shows the current flag value so the user can see the Mac is
    /// back to normal."
    func testTheSleepFlagNoteSaysWhatPmsetSays() {
        XCTAssertNil(AdvancedSettingsCopy.keepAwakeFlagNote(nil, resetIncomplete: false))
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeFlagNote(.cleared, resetIncomplete: false), SettingsCaption(text: "Sleep flag off (SleepDisabled 0)", token: .secondary))
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeFlagNote(.neverSet, resetIncomplete: false), SettingsCaption(text: "Sleep flag never set", token: .secondary))
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeFlagNote(.set, resetIncomplete: false), SettingsCaption(text: "Sleep flag on (SleepDisabled 1): this Mac does not sleep", token: .warning))
        XCTAssertEqual(AdvancedSettingsCopy.keepAwakeFlagNote(.unreadable, resetIncomplete: false), SettingsCaption(text: "Sleep flag unknown: pmset did not answer", token: .secondary))
    }

    /// Review C1: a reset that could not clear the flag, or could not remove the helper, keeps
    /// the helper and says the Mac is not back to normal yet.
    func testAnIncompleteResetSaysTheMacIsNotBackToNormal() {
        XCTAssertNil(AdvancedSettingsCopy.keepAwakeFlagNote(nil, resetIncomplete: true))
        XCTAssertEqual(
            AdvancedSettingsCopy.keepAwakeFlagNote(.set, resetIncomplete: true),
            SettingsCaption(text: "Sleep flag on (SleepDisabled 1): the Mac is not back to normal yet. Press Reset again.", token: .warning)
        )
        XCTAssertEqual(
            AdvancedSettingsCopy.keepAwakeFlagNote(.unreadable, resetIncomplete: true),
            SettingsCaption(text: "Sleep flag unknown: pmset did not answer. The Mac may not be back to normal yet; press Reset again.", token: .warning)
        )
        XCTAssertEqual(
            AdvancedSettingsCopy.keepAwakeFlagNote(.cleared, resetIncomplete: true),
            SettingsCaption(text: "Sleep flag off (SleepDisabled 0), but the helper is still in Login Items. Press Reset again.", token: .warning)
        )
        XCTAssertEqual(
            AdvancedSettingsCopy.keepAwakeFlagNote(.neverSet, resetIncomplete: true),
            SettingsCaption(text: "Sleep flag never set, but the helper is still in Login Items. Press Reset again.", token: .warning)
        )
    }
}
