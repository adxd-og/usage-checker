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
}
