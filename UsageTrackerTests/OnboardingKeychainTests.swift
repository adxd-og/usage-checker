import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 2, ruling 1a: Omelette keeps
/// Claude Code's token in memory only, so onboarding's "Access granted" chip asks Claude Code's
/// item, read silently, not the copy that is empty at every launch; and its words no longer
/// promise a copy of its own or point to a Settings tab that is gone.
final class OnboardingKeychainTests: XCTestCase {
    private func oauth() -> ClaudeCredentials.OAuth {
        let json = """
        {"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1793200000000,
         "scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_max_20x"}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ClaudeCredentials.self, from: Data(json.utf8)).claudeAiOauth
    }

    func testTheChipSaysGrantedWhenClaudeCodesItemReadsSilently() {
        XCTAssertTrue(OnboardingView.keychainGranted(.found(oauth())))
    }

    func testEveryOtherAnswerIsNotGrantedYet() {
        XCTAssertFalse(OnboardingView.keychainGranted(.absent))
        XCTAssertFalse(OnboardingView.keychainGranted(.refused))
        XCTAssertFalse(OnboardingView.keychainGranted(.unreadable("Keychain read failed (status -25300)")))
    }

    func testTheCardPointsToTheButtonWhereItIsNow() {
        let words = OnboardingView.keychainDescription
        XCTAssertTrue(words.contains("Settings → \(SettingsTab.advanced.rawValue) → **\(AdvancedSettingsCopy.keychainTitle)**"))
        XCTAssertTrue(words.contains("in memory only"))
        XCTAssertFalse(words.contains("own copy"), "Omelette keeps no copy of the token")
        XCTAssertFalse(words.contains("Account"), "the tab is Advanced")
    }
}
